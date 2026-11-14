import Foundation
import TokenMeterCore
import UserNotifications

@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()
    private var isAuthorized = false

    private var hasBundleIdentifier: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private override init() {
        super.init()
    }

    public func configureAndRequestPermission() {
        guard hasBundleIdentifier else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.isAuthorized = granted
            }
        }
    }

    public func send(alert: MeterAlert) {
        guard hasBundleIdentifier else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = (alert.severity == .info) ? .default : .defaultCritical

        let req = UNNotificationRequest(
            identifier: "\(alert.id)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    public func sendTestNotification() {
        send(alert: MeterAlert(
            id: "test-notification",
            title: "TokenMeter 通知已就绪 ⚡",
            body: "当订阅额度超过阈值、重置恢复或端点 429 限流时将自动提醒。",
            severity: .info
        ))
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
