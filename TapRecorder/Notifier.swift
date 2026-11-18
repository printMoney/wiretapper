import AppKit
import UserNotifications

/// Shows macOS notifications and reveals the file when one is clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let filePathKey = "filePath"
    private let center = UNUserNotificationCenter.current()
    private let deliveries = DispatchGroup()

    /// Call this as the app launches so clicks on notifications reach us.
    func start() {
        center.delegate = self
    }

    /// The first time, macOS asks the user whether to allow notifications.
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func showSaved(_ url: URL) {
        deliver(title: "Saved: \(url.lastPathComponent)", body: "", fileURL: url, showAlertIfBlocked: false)
    }

    func showProblem(_ error: Error) {
        let fileURL = (error as? RecordingError)?.fileURL
        deliver(title: "Recording problem", body: error.localizedDescription, fileURL: fileURL, showAlertIfBlocked: true)
    }

    /// Gives a last notification a moment to be sent while the app is quitting.
    func waitUntilDelivered() {
        _ = deliveries.wait(timeout: .now() + 1)
    }

    private func deliver(title: String, body: String, fileURL: URL?, showAlertIfBlocked: Bool) {
        deliveries.enter()

        center.getNotificationSettings { [self] settings in
            let isAllowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard isAllowed else {
                // Problems must never go unseen, even with notifications turned off.
                if showAlertIfBlocked { showAlert(title: title, message: body) }
                deliveries.leave()
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let fileURL {
                content.userInfo = [Self.filePathKey: fileURL.path]
            }

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { [self] error in
                if error != nil, showAlertIfBlocked { showAlert(title: title, message: body) }
                deliveries.leave()
            }
        }
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            NSApp.activate()
            alert.runModal()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shows the notification even though TapRecorder is the running app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Runs when the user clicks a notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo[Self.filePathKey] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
