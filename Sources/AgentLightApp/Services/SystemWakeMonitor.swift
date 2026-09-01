@preconcurrency import AppKit

@MainActor
final class SystemLifecycleMonitor {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        resumeNotifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ],
        suspendNotifications: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ],
        resumeHandler: @escaping @MainActor @Sendable () -> Void,
        suspendHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.center = center
        for notification in resumeNotifications {
            observers.append(center.addObserver(
                forName: notification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    resumeHandler()
                }
            })
        }
        for notification in suspendNotifications {
            observers.append(center.addObserver(
                forName: notification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    suspendHandler()
                }
            })
        }
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
