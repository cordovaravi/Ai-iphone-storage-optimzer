import Foundation
import UserNotifications

/// Before-Trip Mode (§3.1.4, F3.3): "I need 20 GB by Friday" → local
/// notification at date-minus-1-day deep-linking back into the plan.
enum BeforeTripScheduler {
    static let notificationId = "com.offloadpro.beforetrip"

    static func schedule(tripDate: Date, targetGB: Int) async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { return }

        let fireDate = tripDate.addingTimeInterval(-86_400)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Trip tomorrow — free up \(targetGB) GB"
        content.body = "Your offload plan is ready. One tap moves it to storage you own."
        content.userInfo = ["deeplink": "offloadpro://smart/plan?target=\(targetGB)"]
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
        try await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationId])
    }
}
