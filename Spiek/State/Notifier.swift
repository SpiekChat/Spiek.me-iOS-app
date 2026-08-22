import Foundation
import UIKit
import UserNotifications

/// Local notifications and the icon badge.
///
/// Spiek has no push server by design, and registers no background task
/// either — no `BGAppRefreshTask`, no background modes. Once iOS suspends
/// the app, nothing runs and nothing can arrive. Notifications and the badge
/// therefore only update while the app is actually running: in the
/// foreground, and in the brief moment of being sent to the background,
/// when `AppModel.syncBadge(announceNew:)` reports whatever the last sync
/// already found. True background delivery would need a scheduled refresh
/// task or a push relay; both are deliberately absent.
@MainActor
enum Notifier {
    private static let newMessageIdentifier = "spiek.new-messages"

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }

    /// Announces messages still unread as the app leaves the foreground —
    /// the last moment any code runs before iOS suspends the process. This
    /// never fires for messages that land *after* suspension; nothing does.
    static func announce(unreadCount: Int, preview: String?) async {
        guard unreadCount > 0 else { return }
        guard await authorizationStatus() == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = unreadCount == 1 ? "New message" : "\(unreadCount) new messages"
        if let preview, !preview.isEmpty {
            content.body = preview
        }
        content.badge = NSNumber(value: unreadCount)
        content.sound = .default

        let request = UNNotificationRequest(identifier: newMessageIdentifier,
                                            content: content,
                                            trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [newMessageIdentifier]
        )
    }
}
