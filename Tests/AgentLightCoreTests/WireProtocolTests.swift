import Testing
@testable import AgentLightCore

@Test("agent states use one persistent BLE LED report")
func directStatusReport() {
    #expect(DirectStatusEncoder.encode(.idle, capsLockOn: true) == 0x02)
    #expect(DirectStatusEncoder.encode(.working, capsLockOn: true) == 0x03)
    #expect(DirectStatusEncoder.encode(.toolRunning, capsLockOn: true) == 0x03)
    #expect(DirectStatusEncoder.encode(.outputting, capsLockOn: true) == 0x03)
    #expect(DirectStatusEncoder.encode(.waiting, capsLockOn: true) == 0x06)
    #expect(DirectStatusEncoder.encode(.complete, capsLockOn: true) == 0x07)
    #expect(DirectStatusEncoder.encode(.error, capsLockOn: false) == 0x04)
}

@Test("Halo75 V2 Raw HID reports expose every rich state")
func halo75V2RawHIDReport() {
    let expectedCodes: [(AgentLightCommand, UInt8)] = [
        (.idle, 0),
        (.working, 1),
        (.toolRunning, 2),
        (.outputting, 3),
        (.waiting, 4),
        (.complete, 5),
        (.error, 6),
    ]

    for (command, stateCode) in expectedCodes {
        let report = Halo75V2RawHIDProtocol.encode(command)
        #expect(report.count == 32)
        #expect(Array(report.prefix(4)) == [0x4E, 0x42, 0x01, 0x01])
        #expect(report[4] == stateCode)
        #expect(Halo75V2RawHIDProtocol.hasValidChecksum(report))
    }
}
