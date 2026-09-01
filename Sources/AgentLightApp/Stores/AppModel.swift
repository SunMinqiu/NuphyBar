import AgentLightCore
import AgentLightHID
import AppKit
import Foundation
import Observation
import OSLog

private let hidLogger = Logger(subsystem: "com.maige.NuphyBar", category: "HID")
private let agentStateLogger = Logger(subsystem: "com.maige.NuphyBar", category: "AgentState")
private let idleHIDSessionRefreshInterval: Int64 = 60

@MainActor
@Observable
final class AppModel {
    var keyboardModel: String?
    var isConnected = false
    var keyboardError: String?
    var integrationError: String?
    var integrationStatuses: [AgentProvider: IntegrationStatus] = [:]
    var hidAccessState: NuPhyHIDAccessState = .unknown
    var integrationNoticeProvider: AgentProvider?

    private let keyboard = KeyboardController()
    private let integrations: IntegrationController
    @ObservationIgnored private var deliveryState = AgentCommandDeliveryState()
    @ObservationIgnored private var deliveryActivity = AgentDeliveryActivity()
    @ObservationIgnored private var agentStateObservation: AgentStateChangeObservation?
    @ObservationIgnored private var agentStateFileChanges = AgentStateFileChangeTracker()
    @ObservationIgnored private var agentExpirationTask: Task<Void, Never>?
    @ObservationIgnored private var agentFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var aulaRealtimeRGBKeepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardConnectionTask: Task<Void, Never>?
    @ObservationIgnored private var integrationNoticeTask: Task<Void, Never>?
    @ObservationIgnored private var systemLifecycleMonitor: SystemLifecycleMonitor?
    @ObservationIgnored private var isDeliveryReady = false

    init() {
        let helperPath = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/agent-light")
            .path
        integrations = IntegrationController(helperPath: helperPath)
        startKeyboardConnectionObserver()
        refreshConnection()
        refreshIntegrations()
        startAgentMonitor()
        startSystemLifecycleMonitor()
    }

    func refreshConnection() {
        hidAccessState = NuPhyHIDTransport.accessState
        if hidAccessState != .granted {
            isConnected = false
            isDeliveryReady = false
            keyboardModel = nil
            keyboardError = nil
            updateAULARealtimeRGBKeepalive()
        }

        Task {
            await keyboard.refresh()
        }
    }

    func requestHIDAccess() {
        _ = NuPhyHIDTransport.requestAccess()
        hidAccessState = NuPhyHIDTransport.accessState

        if hidAccessState == .granted {
            refreshConnection()
        } else {
            openInputMonitoringSettings()
        }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshIntegrations() {
        Task {
            integrationStatuses = await integrations.statuses()
        }
    }

    func toggleIntegration(_ provider: AgentProvider) {
        let shouldInstall = integrationStatuses[provider] == .available
        Task {
            do {
                try await integrations.setInstalled(shouldInstall, provider: provider)
                integrationStatuses = await integrations.statuses()
                showIntegrationNotice(for: provider)
                integrationError = nil
            } catch {
                integrationError = "接入失败：\(error.localizedDescription)"
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard deliveryActivity.begin() else { return }
        keyboardError = nil
        Task {
            defer {
                if deliveryActivity.finish() {
                    deliveryState.stateEventReceived()
                    applyAgentStateIfChanged()
                }
            }
            do {
                try await operation()
            } catch {
                if error is NuPhyHIDError {
                    deliveryState.markFailed()
                }
                keyboardError = error.localizedDescription
                hidLogger.error("Keyboard state send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func startAgentMonitor() {
        agentStateFileChanges.synchronize(with: agentStateFileModificationDate())
        do {
            agentStateObservation = try AgentStateChangeNotification.observe { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleAgentStateChange()
                }
            }
        } catch {
            agentStateLogger.error(
                "Could not register Agent state notifications: \(String(describing: error), privacy: .public)"
            )
        }
        startAgentFallbackMonitor()
        applyAgentStateIfChanged()
    }

    private func startAgentFallbackMonitor() {
        agentFallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self else { return }
                let modificationDate = agentStateFileModificationDate()
                if agentStateFileChanges.changed(to: modificationDate) {
                    handleAgentStateChange()
                }
            }
        }
    }

    private func agentStateFileModificationDate() -> Date? {
        try? AgentStateFile.defaultURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
    }

    private func startKeyboardConnectionObserver() {
        keyboardConnectionTask = Task { [weak self] in
            guard let states = await self?.keyboard.connectionStates() else { return }
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.handleKeyboardConnection(state)
            }
        }
    }

    private func startSystemLifecycleMonitor() {
        systemLifecycleMonitor = SystemLifecycleMonitor(
            resumeHandler: { [weak self] in
                self?.rebuildHIDSessionAfterWake()
            },
            suspendHandler: { [weak self] in
                self?.clearAgentStateForSuspend()
            }
        )
    }

    private func clearAgentStateForSuspend() {
        do {
            try AgentStateFile().clear()
        } catch {
            agentStateLogger.error(
                "Could not clear Agent state before suspend: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func rebuildHIDSessionAfterWake() {
        isDeliveryReady = false
        hidLogger.info("Mac woke from sleep; rebuilding the keyboard HID session")
        Task {
            await keyboard.rebuildSession()
        }
    }

    private func handleKeyboardConnection(_ state: NuPhyHIDConnectionState) {
        hidAccessState = NuPhyHIDTransport.accessState
        switch state {
        case .disconnected:
            isConnected = false
            isDeliveryReady = false
            keyboardModel = nil
            keyboardError = NuPhyHIDError.deviceNotConnected.localizedDescription

        case .connected(let productName, .recovering(let error)):
            keyboardModel = productName
            isConnected = true
            isDeliveryReady = false
            keyboardError = error.localizedDescription

        case .connected(let productName, .rebuilding):
            keyboardModel = productName
            isConnected = true
            isDeliveryReady = false
            keyboardError = nil

        case .connected(let productName, .ready):
            let shouldReplayState = !isDeliveryReady
            keyboardModel = productName
            isConnected = true
            isDeliveryReady = true
            keyboardError = nil
            if shouldReplayState {
                deliveryState.connectionRestored()
                hidLogger.info("Keyboard HID session is ready")
                applyAgentStateIfChanged()
            }

        case .unavailable(let error):
            isConnected = false
            isDeliveryReady = false
            keyboardModel = nil
            keyboardError = error == .permissionDenied ? nil : error.localizedDescription
        }
        updateAULARealtimeRGBKeepalive()
    }

    private func applyAgentStateIfChanged() {
        guard var state = try? AgentStateFile().load() else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let presentation = state.presentation(now: now)
        scheduleAgentExpiration(presentation.nextExpiration, now: now)

        guard hidAccessState == .granted, isConnected, isDeliveryReady else { return }
        if deliveryActivity.isSending {
            deliveryActivity.requestRefresh()
            return
        }
        guard deliveryState.shouldSend(presentation.command) else { return }

        perform {
            try await self.keyboard.send(presentation.command)
            self.deliveryState.markDelivered(presentation.command, now: now)
        }
    }

    private func handleAgentStateChange() {
        agentStateFileChanges.synchronize(with: agentStateFileModificationDate())
        let now = Int64(Date().timeIntervalSince1970)
        if isDeliveryReady,
           keyboardModel?.localizedCaseInsensitiveContains("NuPhy") == true,
           deliveryState.needsSessionRefresh(
               now: now,
               after: idleHIDSessionRefreshInterval
           ) {
            isDeliveryReady = false
            hidLogger.info("Agent event arrived after an idle interval; rebuilding the keyboard HID session")
            Task {
                await keyboard.rebuildSession()
            }
            return
        }
        deliveryState.stateEventReceived()
        applyAgentStateIfChanged()
    }

    private func scheduleAgentExpiration(_ expiration: Int64?, now: Int64) {
        agentExpirationTask?.cancel()
        guard let expiration else {
            agentExpirationTask = nil
            return
        }

        let delay = max(0, expiration - now)
        agentExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            agentExpirationTask = nil
            applyAgentStateIfChanged()
        }
    }

    private func updateAULARealtimeRGBKeepalive() {
        aulaRealtimeRGBKeepaliveTask?.cancel()
        aulaRealtimeRGBKeepaliveTask = nil

        guard hidAccessState == .granted,
              isConnected,
              isDeliveryReady,
              keyboardModel?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("AULA-F99Pro 5.0") == .orderedSame else { return }

        aulaRealtimeRGBKeepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                self?.refreshAULARealtimeRGB()
            }
        }
    }

    private func refreshAULARealtimeRGB() {
        guard hidAccessState == .granted,
              isConnected,
              isDeliveryReady,
              keyboardModel?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("AULA-F99Pro 5.0") == .orderedSame,
              var state = try? AgentStateFile().load() else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let command = state.presentation(now: now).command
        guard command != .idle else { return }

        perform {
            try await self.keyboard.send(command)
            self.deliveryState.markDelivered(command, now: now)
        }
    }

    private func showIntegrationNotice(for provider: AgentProvider) {
        integrationNoticeProvider = provider
        integrationNoticeTask?.cancel()
        integrationNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.integrationNoticeProvider = nil
        }
    }
}

struct AgentCommandDeliveryState {
    private var lastDeliveredCommand: AgentLightCommand?
    private var lastDeliveredAt: Int64?
    private var canAttemptDelivery = true

    func shouldSend(_ command: AgentLightCommand) -> Bool {
        canAttemptDelivery && command != lastDeliveredCommand
    }

    mutating func markDelivered(_ command: AgentLightCommand, now: Int64) {
        lastDeliveredCommand = command
        lastDeliveredAt = now
        canAttemptDelivery = true
    }

    mutating func markFailed() {
        lastDeliveredCommand = nil
        lastDeliveredAt = nil
        canAttemptDelivery = false
    }

    mutating func connectionRestored() {
        lastDeliveredCommand = nil
        lastDeliveredAt = nil
        canAttemptDelivery = true
    }

    mutating func stateEventReceived() {
        guard canAttemptDelivery else { return }
        lastDeliveredCommand = nil
    }

    func needsSessionRefresh(now: Int64, after interval: Int64) -> Bool {
        guard canAttemptDelivery, let lastDeliveredAt else { return false }
        return max(0, now - lastDeliveredAt) >= interval
    }
}

struct AgentStateFileChangeTracker {
    private var lastModificationDate: Date?
    private var isSynchronized = false

    mutating func synchronize(with modificationDate: Date?) {
        lastModificationDate = modificationDate
        isSynchronized = true
    }

    mutating func changed(to modificationDate: Date?) -> Bool {
        guard isSynchronized else {
            synchronize(with: modificationDate)
            return false
        }
        guard modificationDate != lastModificationDate else { return false }
        lastModificationDate = modificationDate
        return true
    }
}

struct AgentDeliveryActivity {
    private(set) var isSending = false
    private var refreshPending = false

    mutating func begin() -> Bool {
        guard !isSending else { return false }
        isSending = true
        return true
    }

    mutating func requestRefresh() {
        if isSending {
            refreshPending = true
        }
    }

    mutating func finish() -> Bool {
        let shouldRefresh = refreshPending
        isSending = false
        refreshPending = false
        return shouldRefresh
    }
}
