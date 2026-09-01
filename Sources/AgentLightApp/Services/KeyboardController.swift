import AgentLightCore
import AgentLightHID

actor KeyboardController {
    private let transport = NuPhyHIDTransport()

    func connectionStates() -> AsyncStream<NuPhyHIDConnectionState> {
        transport.connectionStates
    }

    func refresh() {
        transport.refresh()
    }

    func rebuildSession() {
        transport.rebuildSession()
    }

    func send(_ command: AgentLightCommand, productName: String?) throws {
        guard Self.usesFreshSession(productName: productName) else {
            try transport.send(command)
            return
        }

        do {
            try NuPhyHIDTransport().send(command)
        } catch {
            transport.rebuildSession()
            throw error
        }
    }

    static func usesFreshSession(productName: String?) -> Bool {
        productName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("nuphy") == true
    }
}
