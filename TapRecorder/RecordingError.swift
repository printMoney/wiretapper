import Foundation

/// Everything that can go wrong while recording, in words a person can act on.
enum RecordingError: LocalizedError {
    case couldNotCreateFolder(String)
    case couldNotCreateFile(OSStatus)
    case couldNotStartCapture(String, OSStatus)
    case noAudioCaptured
    case writeFailed(URL, OSStatus)
    case fileSizeLimitReached(URL)
    case couldNotFinishFile(URL, OSStatus)
    case outputDeviceChanged(URL)

    /// The file this problem is about, if one was saved.
    var fileURL: URL? {
        switch self {
        case .writeFailed(let url, _),
             .fileSizeLimitReached(let url),
             .couldNotFinishFile(let url, _),
             .outputDeviceChanged(let url):
            return url
        case .couldNotCreateFolder, .couldNotCreateFile, .couldNotStartCapture, .noAudioCaptured:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .couldNotCreateFolder(let path):
            return "TapRecorder could not create the folder \(path)."
        case .couldNotCreateFile(let status):
            return "TapRecorder could not create the recording file. (Error \(status))"
        case .couldNotStartCapture(let step, let status):
            return "TapRecorder could not start recording: \(step). (Error \(status))"
        case .noAudioCaptured:
            return "No audio was captured, so no file was saved."
        case .writeFailed(let url, let status):
            return "Recording stopped because writing to disk failed. Check that the disk has free space. "
                + "\(url.lastPathComponent) may be incomplete. (Error \(status))"
        case .fileSizeLimitReached(let url):
            return "Recording stopped because this file type can't be larger than 4 GB. "
                + "Everything up to that point was saved as \(url.lastPathComponent)."
        case .couldNotFinishFile(let url, let status):
            return "\(url.lastPathComponent) could not be finished and may be corrupt. (Error \(status))"
        case .outputDeviceChanged(let url):
            return "Recording stopped because your sound output changed. "
                + "Everything up to that point was saved as \(url.lastPathComponent)."
        }
    }
}
