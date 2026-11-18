import Foundation

/// The user's choices, remembered between launches.
final class AppSettings {
    private enum Key {
        static let format = "recordingFormat"
        static let outputFolder = "outputFolderPath"
    }

    private let defaults = UserDefaults.standard

    /// The format used for the next recording. WAV until the user picks another.
    var format: RecordingFormat {
        get {
            let savedValue = defaults.string(forKey: Key.format) ?? ""
            return RecordingFormat(rawValue: savedValue) ?? .wav
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.format)
        }
    }

    /// Where recordings are saved. ~/Music/TapRecorder until the user picks another.
    var outputFolder: URL {
        get {
            if let savedPath = defaults.string(forKey: Key.outputFolder) {
                return URL(fileURLWithPath: savedPath, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/TapRecorder", isDirectory: true)
        }
        set {
            defaults.set(newValue.path, forKey: Key.outputFolder)
        }
    }
}
