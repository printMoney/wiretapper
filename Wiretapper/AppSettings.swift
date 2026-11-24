import Foundation

/// The user's choices, remembered between launches.
final class AppSettings {
    private enum Key {
        static let format = "recordingFormat"
        static let outputFolder = "outputFolderPath"
        static let unfinishedRecording = "unfinishedRecordingPath"
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

    /// Where recordings are saved. ~/Music/Wiretapper until the user picks another.
    var outputFolder: URL {
        get {
            if let savedPath = defaults.string(forKey: Key.outputFolder) {
                return URL(fileURLWithPath: savedPath, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/Wiretapper", isDirectory: true)
        }
        set {
            defaults.set(newValue.path, forKey: Key.outputFolder)
        }
    }

    /// The file being recorded, remembered until it is finished. If the app
    /// crashes or is force quit, this tells the next launch to warn the user.
    var unfinishedRecordingPath: String? {
        get { defaults.string(forKey: Key.unfinishedRecording) }
        set { defaults.set(newValue, forKey: Key.unfinishedRecording) }
    }
}
