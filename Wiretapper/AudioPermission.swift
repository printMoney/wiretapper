import AppKit

/// Checks and requests permission to record system audio.
///
/// Apple has no public way to ask "has the user allowed this?". Without an
/// answer, a denied app would simply record silence. So, like other open-source
/// Core Audio tap projects, we look up macOS's privacy functions while the app
/// is running. If they are ever missing, recording just goes ahead and macOS
/// shows its own prompt.
enum AudioPermission {
    private static let serviceName = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    private static let privacyLibrary = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// Calls `completion` on the main thread with true if recording is allowed.
    /// The first time, this makes macOS show its permission prompt.
    static func request(completion: @escaping (Bool) -> Void) {
        guard let privacyLibrary,
              let preflightSymbol = dlsym(privacyLibrary, "TCCAccessPreflight"),
              let requestSymbol = dlsym(privacyLibrary, "TCCAccessRequest") else {
            completion(true)
            return
        }

        let preflight = unsafeBitCast(preflightSymbol, to: PreflightFunction.self)
        switch preflight(serviceName, nil) {
        case 0: // Already allowed.
            completion(true)
        case 1: // Already denied.
            completion(false)
        default: // Not decided yet, so ask.
            let requestAccess = unsafeBitCast(requestSymbol, to: RequestFunction.self)
            requestAccess(serviceName, nil) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// Opens the privacy section of System Settings.
    static func openSystemSettings() {
        let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}
