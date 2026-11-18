/// The audio file formats a user can choose from the menu.
enum RecordingFormat: String, CaseIterable {
    case m4a
    case flac
    case wav
    case aiff

    /// The text shown for this format in the menu.
    var menuTitle: String {
        switch self {
        case .m4a: return "M4A (AAC 320 kbps)"
        case .flac: return "FLAC"
        case .wav: return "WAV (24-bit)"
        case .aiff: return "AIFF (24-bit)"
        }
    }

    /// The ending of the saved file's name.
    var fileExtension: String {
        rawValue
    }

    /// WAV and AIFF files can't grow past 4 GB, about 4 hours at 48 kHz.
    var hasFourGigabyteLimit: Bool {
        self == .wav || self == .aiff
    }
}
