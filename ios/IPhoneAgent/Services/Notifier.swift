import Foundation
import UserNotifications

/// Local notifications for runs: done / failed / needs help / screen sharing stopped / board disconnected, with
/// actions (Review, Retry, Stop, Continue, Skip, Take over). Tapping one opens the run's review.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String { case done, failed, help, takeover, capture, board, mouse }
    enum Action: String { case review, retry, stop, resume, skip, takeOver }

    /// Called with the action (nil = the notification itself was tapped) and the run id.
    var onAction: ((Action?, String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    static let askedKey = "askedNotifications"

    override init() {
        super.init()
        center.delegate = self
        let review = UNNotificationAction(identifier: Action.review.rawValue, title: String(localized: "Review"),
                                          options: [.foreground])
        let retry = UNNotificationAction(identifier: Action.retry.rawValue, title: String(localized: "Retry"),
                                         options: [.foreground])
        let stop = UNNotificationAction(identifier: Action.stop.rawValue, title: String(localized: "Stop"),
                                        options: [.destructive])
        let resume = UNNotificationAction(identifier: Action.resume.rawValue, title: String(localized: "Continue"))
        let skip = UNNotificationAction(identifier: Action.skip.rawValue, title: String(localized: "Skip step"))
        let takeOver = UNNotificationAction(identifier: Action.takeOver.rawValue, title: String(localized: "Take over"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.done.rawValue, actions: [review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.failed.rawValue, actions: [review, retry], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.help.rawValue, actions: [takeOver, skip, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.takeover.rawValue, actions: [resume, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.capture.rawValue, actions: [stop, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.board.rawValue, actions: [stop, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.mouse.rawValue, actions: [stop, review], intentIdentifiers: []),
        ])
    }

    /// Asked once, on the first Start (with a one-line reason shown by the app first).
    static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    func requestPermission() async {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ kind: Kind, title: String, body: String, run: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind.rawValue
        content.userInfo = ["run": run]
        // The Live Activity carries task status. Keep notification history quiet so
        // banners and sounds do not cover controls the agent is trying to observe.
        content.sound = nil
        content.interruptionLevel = .passive
        center.removeDeliveredNotifications(withIdentifiers: [Kind.help.rawValue, Kind.takeover.rawValue])
        center.add(UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil))
    }

    func clearHelp() {
        center.removeDeliveredNotifications(withIdentifiers: [Kind.help.rawValue, Kind.takeover.rawValue])
    }

    /// The link is back: the "restart sharing / check the board / connect the mouse" asks are stale.
    func clearLinkAsks() {
        center.removeDeliveredNotifications(withIdentifiers: [Kind.capture.rawValue, Kind.board.rawValue, Kind.mouse.rawValue])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler([.list]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let run = response.notification.request.content.userInfo["run"] as? String ?? ""
        let id = response.actionIdentifier
        let action = id == UNNotificationDefaultActionIdentifier ? nil : Action(rawValue: id)
        deliver(action, run: run, completion: completionHandler)
    }

    /// UIKit's completion can update the app snapshot; it must run on the main thread,
    /// together with the action. The async delegate bridge completed on a worker thread.
    nonisolated func deliver(_ action: Action?, run: String, completion: @escaping () -> Void) {
        Task { @MainActor in
            onAction?(action, run)
            completion()
        }
    }
}
