import AppKit
import UserNotifications

enum SettingsKey {
    static let sounds = "soundsEnabled"
    static let notifications = "notificationsEnabled"
}

/// Sounds, system notifications and the Dock badge.
@MainActor
enum AlertService {
    private static let delegate = ForegroundDelegate()

    /// UNUserNotificationCenter crashes outside an app bundle (for example `swift run`).
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, success: Bool) {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: SettingsKey.sounds) as? Bool ?? true {
            NSSound(named: success ? "Glass" : "Basso")?.play()
        }

        guard canNotify, defaults.object(forKey: SettingsKey.notifications) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    static func setDockBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}

/// Shows banners even while the app is in front; the app plays its own sounds.
private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
