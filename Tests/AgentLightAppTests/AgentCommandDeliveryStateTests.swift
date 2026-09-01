import AgentLightCore
import Foundation
import Testing
@testable import AgentLightApp

@Test("reconnecting invalidates the last delivered keyboard state")
func reconnectingReplaysTheCurrentState() {
    var delivery = AgentCommandDeliveryState()

    #expect(delivery.shouldSend(.working))
    delivery.markDelivered(.working, now: 100)
    #expect(!delivery.shouldSend(.working))

    delivery.connectionRestored()

    #expect(delivery.shouldSend(.working))
}

@Test("a new Agent event replays an unchanged keyboard state")
func agentEventReplaysTheCurrentState() {
    var delivery = AgentCommandDeliveryState()

    delivery.markDelivered(.working, now: 100)
    #expect(!delivery.shouldSend(.working))

    delivery.stateEventReceived()

    #expect(delivery.shouldSend(.working))
}

@Test("a failed delivery waits for the HID session to recover")
func failedDeliveryWaitsForRecovery() {
    var delivery = AgentCommandDeliveryState()

    #expect(delivery.shouldSend(.waiting))
    delivery.markFailed()

    #expect(!delivery.shouldSend(.waiting))
    delivery.stateEventReceived()
    #expect(!delivery.shouldSend(.waiting))

    delivery.connectionRestored()

    #expect(delivery.shouldSend(.waiting))
}

@Test("state changes during a HID send are coalesced into one follow-up refresh")
func stateChangesDuringSendAreCoalesced() {
    var activity = AgentDeliveryActivity()
    var delivery = AgentCommandDeliveryState()

    let began = activity.begin()
    #expect(began)
    activity.requestRefresh()
    activity.requestRefresh()
    delivery.markDelivered(.working, now: 100)

    let shouldRefresh = activity.finish()
    if shouldRefresh {
        delivery.stateEventReceived()
    }
    #expect(shouldRefresh)
    #expect(!activity.isSending)
    #expect(delivery.shouldSend(.working))
}

@Test("a completed HID send does not refresh without a new state event")
func completedSendWithoutStateChangeDoesNotRefresh() {
    var activity = AgentDeliveryActivity()

    let began = activity.begin()
    let shouldRefresh = activity.finish()
    #expect(began)
    #expect(!shouldRefresh)
}

@Test("a NuPhy HID session refreshes after a quiet delivery interval")
func idleDeliveryIntervalRefreshesTheSession() {
    var delivery = AgentCommandDeliveryState()

    #expect(!delivery.needsSessionRefresh(now: 100, after: 60))
    delivery.markDelivered(.working, now: 100)
    #expect(!delivery.needsSessionRefresh(now: 159, after: 60))
    #expect(delivery.needsSessionRefresh(now: 160, after: 60))

    delivery.connectionRestored()
    #expect(!delivery.needsSessionRefresh(now: 300, after: 60))
}

@Test("state file watchdog detects changes after initial synchronization")
func stateFileWatchdogDetectsChanges() {
    var tracker = AgentStateFileChangeTracker()
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 101)

    let initialChange = tracker.changed(to: first)
    let repeatedInitialChange = tracker.changed(to: first)
    let laterChange = tracker.changed(to: second)
    let repeatedLaterChange = tracker.changed(to: second)
    let deletionChange = tracker.changed(to: nil)

    #expect(!initialChange)
    #expect(!repeatedInitialChange)
    #expect(laterChange)
    #expect(!repeatedLaterChange)
    #expect(deletionChange)
}
