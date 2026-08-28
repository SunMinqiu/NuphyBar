import AgentLightCore
import CoreGraphics
import Foundation
import IOKit.hid
import IOKit.hidsystem

public enum NuPhyHIDAccessState: Equatable, Sendable {
    case granted
    case denied
    case unknown
}

public enum NuPhyHIDError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case permissionDenied
    case managerOpenFailed(IOReturn)
    case deviceNotConnected
    case reportFailed(IOReturn)

    public var description: String {
        switch self {
        case .permissionDenied: return "keyboard HID access has not been granted"
        case .managerOpenFailed(let status): return "could not open the HID manager (\(hex(status)))"
        case .deviceNotConnected: return "no compatible NuPhy keyboard is connected"
        case .reportFailed(let status): return "sending a keyboard report failed (\(hex(status)))"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要允许 NuphyBar 访问键盘 HID 接口"
        case .managerOpenFailed: return "无法访问 macOS HID 设备管理器"
        case .deviceNotConnected: return "未找到已连接的 NuphyBar 兼容 NuPhy 键盘"
        case .reportFailed: return "无法向 NuPhy 键盘发送灯光状态"
        }
    }

    private func hex(_ status: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: status), radix: 16)
    }
}

public enum NuPhyHIDDeliveryState: Equatable, Sendable {
    case ready
    case rebuilding
    case recovering(NuPhyHIDError)
}

public enum NuPhyHIDConnectionState: Equatable, Sendable {
    case disconnected
    case connected(productName: String, delivery: NuPhyHIDDeliveryState)
    case unavailable(NuPhyHIDError)
}

enum NuPhyHIDDeviceProfile: Int, Equatable, Sendable {
    case halo75V2USB = 0
    case bluetoothKeyboardLED = 1
}

public final class NuPhyHIDTransport: @unchecked Sendable {
    static var deviceMatchingProperties: [[String: Any]] {
        [
            [
                kIOHIDTransportKey as String: "Bluetooth Low Energy",
                kIOHIDDeviceUsagePageKey as String: 1,
                kIOHIDDeviceUsageKey as String: 6,
            ],
            [
                kIOHIDVendorIDKey as String: 0x19F5,
                kIOHIDProductIDKey as String: 0x32F5,
            ],
        ]
    }

    public let connectionStates: AsyncStream<NuPhyHIDConnectionState>

    private let queue = DispatchQueue(label: "com.maige.NuphyBar.HID")
    private let stateContinuation: AsyncStream<NuPhyHIDConnectionState>.Continuation
    private var manager: IOHIDManager?
    private var activeSessionID: UUID?
    private var cancellingSessionID: UUID?
    private var currentDevice: IOHIDDevice?
    private var currentDeviceProfile: NuPhyHIDDeviceProfile?
    private var recoveryProductName: String?
    private var currentState: NuPhyHIDConnectionState?
    private var reconnectBackoff = HIDReconnectBackoff()
    private var restartWorkItem: DispatchWorkItem?
    private var pendingRestartDelay: TimeInterval?
    private var isStopped = false

    public init() {
        let stream = AsyncStream<NuPhyHIDConnectionState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        connectionStates = stream.stream
        stateContinuation = stream.continuation
        queue.sync { startManager() }
    }

    deinit {
        stateContinuation.finish()
        queue.sync {
            isStopped = true
            restartWorkItem?.cancel()
            restartWorkItem = nil
            pendingRestartDelay = nil
            cancelManager()
        }
    }

    public static var accessState: NuPhyHIDAccessState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    @discardableResult
    public static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func isCompatible(
        productName: String?,
        transport: String?,
        maxOutputReportSize: Int?,
        usagePage: Int? = nil,
        usage: Int? = nil,
        vendorID: Int? = nil,
        productID: Int? = nil
    ) -> Bool {
        profile(
            productName: productName,
            transport: transport,
            maxOutputReportSize: maxOutputReportSize,
            usagePage: usagePage,
            usage: usage,
            vendorID: vendorID,
            productID: productID
        ) != nil
    }

    static func profile(
        productName: String?,
        transport: String?,
        maxOutputReportSize: Int?,
        usagePage: Int?,
        usage: Int?,
        vendorID: Int?,
        productID: Int?
    ) -> NuPhyHIDDeviceProfile? {
        guard let productName,
              productName.range(of: "NuPhy", options: [.anchored, .caseInsensitive]) != nil,
              let maxOutputReportSize else { return nil }

        if transport == "USB",
           productName.caseInsensitiveCompare("NuPhy Halo75 V2 NuphyBar") == .orderedSame,
           vendorID == 0x19F5,
           productID == 0x32F5,
           usagePage == 0xFF60,
           usage == 0x61,
           maxOutputReportSize >= Halo75V2RawHIDProtocol.reportLength {
            return .halo75V2USB
        }

        if transport == "Bluetooth Low Energy", maxOutputReportSize >= 2 {
            return .bluetoothKeyboardLED
        }
        return nil
    }

    public func refresh() {
        queue.async { [weak self] in
            self?.refreshManager()
        }
    }

    public func rebuildSession() {
        queue.async { [weak self] in
            self?.rebuildManagerSession()
        }
    }

    public func describe() throws -> String {
        try queue.sync {
            guard let device = currentDevice else {
                throw NuPhyHIDError.deviceNotConnected
            }
            let name = productName(of: device) ?? "NuPhy keyboard"
            let transport = transport(of: device) ?? "unknown"
            let maxOutput = maxOutputReportSize(of: device)
            let reportDescription = currentDeviceProfile == .halo75V2USB
                ? "Raw HID output, report ID 0"
                : "Keyboard LED output, report ID 1"
            return [
                "Device: \(name)",
                "Transport: \(transport)",
                "Protocol: \(reportDescription)",
                "Max output report size: \(maxOutput.map(String.init) ?? "unknown") bytes",
            ].joined(separator: "\n")
        }
    }

    public func send(_ command: AgentLightCommand) throws {
        try AgentLightTransmissionLock().withLock {
            try queue.sync {
                guard Self.accessState == .granted else {
                    refreshManager()
                    throw NuPhyHIDError.permissionDenied
                }
                guard let currentDevice else {
                    throw NuPhyHIDError.deviceNotConnected
                }
                guard let currentDeviceProfile else {
                    throw NuPhyHIDError.deviceNotConnected
                }

                do {
                    switch currentDeviceProfile {
                    case .halo75V2USB:
                        try setRawOutputReport(
                            Halo75V2RawHIDProtocol.encode(command),
                            on: currentDevice
                        )
                    case .bluetoothKeyboardLED:
                        let capsLockOn = CGEventSource.flagsState(.combinedSessionState)
                            .contains(.maskAlphaShift)
                        let mask = DirectStatusEncoder.encode(command, capsLockOn: capsLockOn)
                        try setKeyboardLEDOutputReport(mask, on: currentDevice)
                    }
                    reconnectBackoff.reset()
                } catch let error as NuPhyHIDError {
                    recoverFromReportFailure(error, productName: productName(of: currentDevice))
                    throw error
                }
            }
        }
    }

    private func startManager() {
        guard !isStopped, manager == nil, cancellingSessionID == nil else { return }
        guard Self.accessState == .granted else {
            publish(.unavailable(.permissionDenied))
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(
            manager,
            Self.deviceMatchingProperties as CFArray
        )
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            publish(.unavailable(.managerOpenFailed(status)))
            scheduleManagerStart(after: reconnectBackoff.nextDelay())
            return
        }

        let sessionID = UUID()
        let context = ManagerCallbackContext(owner: self, manager: manager, sessionID: sessionID)
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            Self.deviceMatchedCallback,
            contextPointer
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            Self.deviceRemovedCallback,
            contextPointer
        )
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) { [context] in
            _ = IOHIDManagerClose(context.manager, IOOptionBits(kIOHIDOptionsTypeNone))
            context.owner?.managerDidCancel(sessionID: context.sessionID)
        }

        self.manager = manager
        activeSessionID = sessionID
        IOHIDManagerActivate(manager)
        selectConnectedDevice(from: manager, sessionID: sessionID)
    }

    private func refreshManager() {
        guard Self.accessState == .granted else {
            recoveryProductName = nil
            currentDevice = nil
            currentDeviceProfile = nil
            reconnectBackoff.reset()
            pendingRestartDelay = nil
            restartWorkItem?.cancel()
            restartWorkItem = nil
            cancelManager()
            publish(.unavailable(.permissionDenied))
            return
        }

        reconnectBackoff.reset()
        if cancellingSessionID != nil {
            pendingRestartDelay = 0
        } else if let manager, let activeSessionID {
            selectConnectedDevice(from: manager, sessionID: activeSessionID)
        } else {
            restartWorkItem?.cancel()
            restartWorkItem = nil
            startManager()
        }
    }

    private func rebuildManagerSession() {
        guard !isStopped else { return }
        guard Self.accessState == .granted else {
            refreshManager()
            return
        }

        restartWorkItem?.cancel()
        restartWorkItem = nil
        reconnectBackoff.reset()

        let connectedProductName = currentDevice.flatMap { productName(of: $0) }
        if let productName = connectedProductName ?? recoveryProductName {
            currentDevice = nil
            recoveryProductName = productName
            publish(.connected(productName: productName, delivery: .rebuilding))
        }

        if cancellingSessionID != nil {
            pendingRestartDelay = 0
            return
        } else if manager != nil {
            pendingRestartDelay = 0
            cancelManager()
        } else {
            pendingRestartDelay = nil
            startManager()
        }
    }

    private func selectConnectedDevice(from manager: IOHIDManager, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices
                .filter(isCompatible)
                .min(by: { profile(of: $0).rawValue < profile(of: $1).rawValue }) else {
            currentDevice = nil
            currentDeviceProfile = nil
            recoveryProductName = nil
            publish(.disconnected)
            return
        }
        handleMatchedDevice(device, sessionID: sessionID)
    }

    private func handleMatchedDevice(_ device: IOHIDDevice, sessionID: UUID) {
        guard activeSessionID == sessionID, let matchedProfile = optionalProfile(of: device) else { return }
        if let currentDevice, CFEqual(currentDevice, device) { return }
        if let currentDeviceProfile, currentDeviceProfile.rawValue <= matchedProfile.rawValue {
            return
        }

        let wasRecovering = recoveryProductName != nil
        currentDevice = device
        currentDeviceProfile = matchedProfile
        recoveryProductName = nil
        if !wasRecovering {
            reconnectBackoff.reset()
        }
        publish(.connected(
            productName: productName(of: device) ?? "NuPhy 键盘",
            delivery: .ready
        ))
    }

    private func handleRemovedDevice(_ device: IOHIDDevice, sessionID: UUID) {
        guard activeSessionID == sessionID,
              let currentDevice,
              CFEqual(currentDevice, device) else { return }
        self.currentDevice = nil
        currentDeviceProfile = nil
        recoveryProductName = nil
        reconnectBackoff.reset()
        if let manager {
            selectConnectedDevice(from: manager, sessionID: sessionID)
            return
        }
        publish(.disconnected)
    }

    private func recoverFromReportFailure(_ error: NuPhyHIDError, productName: String?) {
        let productName = productName ?? "NuPhy 键盘"
        recoveryProductName = productName
        currentDevice = nil
        currentDeviceProfile = nil
        publish(.connected(
            productName: productName,
            delivery: .recovering(error)
        ))
        pendingRestartDelay = reconnectBackoff.nextDelay()
        cancelManager()
    }

    private func cancelManager() {
        guard let manager, let activeSessionID else { return }
        self.manager = nil
        self.activeSessionID = nil
        cancellingSessionID = activeSessionID
        IOHIDManagerCancel(manager)
    }

    private func managerDidCancel(sessionID: UUID) {
        guard cancellingSessionID == sessionID else { return }
        cancellingSessionID = nil
        guard let delay = pendingRestartDelay, !isStopped else { return }
        pendingRestartDelay = nil
        scheduleManagerStart(after: delay)
    }

    private func scheduleManagerStart(after delay: TimeInterval) {
        guard !isStopped else { return }
        restartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.startManager()
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func publish(_ state: NuPhyHIDConnectionState) {
        guard state != currentState else { return }
        currentState = state
        stateContinuation.yield(state)
    }

    private func isCompatible(_ device: IOHIDDevice) -> Bool {
        optionalProfile(of: device) != nil
    }

    private func profile(of device: IOHIDDevice) -> NuPhyHIDDeviceProfile {
        optionalProfile(of: device)!
    }

    private func optionalProfile(of device: IOHIDDevice) -> NuPhyHIDDeviceProfile? {
        Self.profile(
            productName: productName(of: device),
            transport: transport(of: device),
            maxOutputReportSize: maxOutputReportSize(of: device),
            usagePage: integerProperty(kIOHIDPrimaryUsagePageKey, of: device),
            usage: integerProperty(kIOHIDPrimaryUsageKey, of: device),
            vendorID: integerProperty(kIOHIDVendorIDKey, of: device),
            productID: integerProperty(kIOHIDProductIDKey, of: device)
        )
    }

    private func productName(of device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    }

    private func transport(of device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
    }

    private func maxOutputReportSize(of device: IOHIDDevice) -> Int? {
        integerProperty(kIOHIDMaxOutputReportSizeKey, of: device)
    }

    private func integerProperty(_ key: String, of device: IOHIDDevice) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString)
            .flatMap { $0 as? NSNumber }?.intValue
    }

    private func setKeyboardLEDOutputReport(_ mask: UInt8, on device: IOHIDDevice) throws {
        var report: [UInt8] = [1, mask]
        let reportCount = report.count
        let status = report.withUnsafeMutableBytes { bytes in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                1,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                reportCount
            )
        }
        guard status == kIOReturnSuccess else {
            throw NuPhyHIDError.reportFailed(status)
        }
    }

    private func setRawOutputReport(_ report: [UInt8], on device: IOHIDDevice) throws {
        var report = report
        let reportCount = report.count
        let status = report.withUnsafeMutableBytes { bytes in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                0,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                reportCount
            )
        }
        guard status == kIOReturnSuccess else {
            throw NuPhyHIDError.reportFailed(status)
        }
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = {
        context, result, _, device in
        guard result == kIOReturnSuccess, let context else { return }
        let callbackContext = Unmanaged<ManagerCallbackContext>
            .fromOpaque(context).takeUnretainedValue()
        callbackContext.owner?.handleMatchedDevice(
            device,
            sessionID: callbackContext.sessionID
        )
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = {
        context, _, _, device in
        guard let context else { return }
        let callbackContext = Unmanaged<ManagerCallbackContext>
            .fromOpaque(context).takeUnretainedValue()
        callbackContext.owner?.handleRemovedDevice(
            device,
            sessionID: callbackContext.sessionID
        )
    }

    private final class ManagerCallbackContext: @unchecked Sendable {
        weak var owner: NuPhyHIDTransport?
        let manager: IOHIDManager
        let sessionID: UUID

        init(owner: NuPhyHIDTransport, manager: IOHIDManager, sessionID: UUID) {
            self.owner = owner
            self.manager = manager
            self.sessionID = sessionID
        }
    }
}
