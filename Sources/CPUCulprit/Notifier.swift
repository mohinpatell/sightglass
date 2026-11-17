import CulpritCore
import UserNotifications

/// Posts alerts as system notifications.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called on the main queue when the person presses "Stop alerts about this app".
    var onMute: ((String) -> Void)?

    /// The notification system needs a real app bundle, which a bare test binary lacks.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Call once at launch. Sets up the mute button and lets banners show while the panel is open.
    func start() {
        guard let center else { return }
        center.delegate = self
        let mute = UNNotificationAction(identifier: "mute", title: "Stop alerts about this app")
        center.setNotificationCategories([UNNotificationCategory(identifier: "app", actions: [mute], intentIdentifiers: [])])
    }

    /// macOS asks the person once. Called when the first alert is switched on.
    func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ alert: Alert, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // Silent unless asked: the Mac may be in a lecture or a meeting.
        content.sound = sound ? .default : nil
        if let app = alert.app {
            content.categoryIdentifier = "app"
            content.userInfo = ["app": app]
        }
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "mute",
           let app = response.notification.request.content.userInfo["app"] as? String {
            DispatchQueue.main.async { self.onMute?(app) }
        }
        completionHandler()
    }
}
