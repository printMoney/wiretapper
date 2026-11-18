import AppKit

/// Receives app-wide events from macOS, such as "the app has finished launching".
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the menu bar icon. We keep it here so it stays alive while the app runs.
    private var statusBarController: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // This must happen early so a click on an old notification is not missed.
        Notifier.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.finishRecordingBeforeQuit()
    }
}
