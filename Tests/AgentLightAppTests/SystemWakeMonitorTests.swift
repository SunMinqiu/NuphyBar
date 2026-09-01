import Foundation
import Testing
@testable import AgentLightApp

@MainActor
private final class LifecycleCounter {
    var resumes = 0
    var suspends = 0
}

@MainActor
@Test("workspace lifecycle notifications invoke their recovery handlers")
func workspaceLifecycleInvokesRecoveryHandlers() {
    let center = NotificationCenter()
    let resume = Notification.Name("NuphyBar.Tests.resume")
    let suspend = Notification.Name("NuphyBar.Tests.suspend")
    let count = LifecycleCounter()
    let monitor = SystemLifecycleMonitor(
        center: center,
        resumeNotifications: [resume],
        suspendNotifications: [suspend],
        resumeHandler: { count.resumes += 1 },
        suspendHandler: { count.suspends += 1 }
    )

    center.post(name: suspend, object: nil)
    center.post(name: resume, object: nil)

    #expect(count.suspends == 1)
    #expect(count.resumes == 1)
    withExtendedLifetime(monitor) {}
}
