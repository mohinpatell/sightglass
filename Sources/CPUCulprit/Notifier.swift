import CulpritCore
import UserNotifications

/// Posts alerts as silent system notifications.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// The notification system needs a real app bundle, which a bare test binary lacks.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Call once at launch so banners also show while the panel is open.
    func start() {
        center?.delegate = self
    }

    /// macOS asks the person once. Called when the first alert is switched on.
    func requestPermission() {
        center?.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // No sound on purpose: the Mac may be in a lecture or a meeting.
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
