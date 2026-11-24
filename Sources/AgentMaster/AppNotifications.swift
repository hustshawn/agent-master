import AppKit
import UserNotifications

/// Tells the user when a session needs them (ADR 0017): a request waits on a card, or a turn ended.
/// UNUserNotificationCenter needs a bundle id, so this is on only in the .app `scripts/bundle.sh` builds,
/// not under `swift run`. A click brings the app forward with that session selected.
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Called on the main thread with the session id of a clicked notification.
    var onOpen: ((String) -> Void)?
    private let enabled = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    func start() {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `id` replaces an earlier notification with the same id (one per request, one per session's turn).
    func post(id: String, title: String, body: String, sessionId: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(id: String) {
        guard enabled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// The app decides whether to post at all (not for the session in front of the user), so show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let sessionId { self?.onOpen?(sessionId) }
            completionHandler()
        }
    }
}
