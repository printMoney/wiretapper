import Foundation

/// Everything that can go wrong while recording, in words a person can act on.
enum RecordingError: LocalizedError {
    case couldNotCreateFolder(String)
    case notEnoughDiskSpace(String)
    case couldNotCreateFile(OSStatus)
    case couldNotStartCapture(String, OSStatus)
    case noAudioCaptured
    case writeFailed(URL, OSStatus)
    case diskAlmostFull(URL)
    case fileSizeLimitReached(URL)
    case couldNotFinishFile(URL, OSStatus)
    case couldNotFinishInTime(URL)
    case outputDeviceChanged(URL)
    case unfinishedFromLastTime(URL)

    /// The file this problem is about, if one was saved.
    var fileURL: URL? {
        switch self {
        case .writeFailed(let url, _),
             .diskAlmostFull(let url),
             .fileSizeLimitReached(let url),
             .couldNotFinishFile(let url, _),
             .couldNotFinishInTime(let url),
             .outputDeviceChanged(let url),
             .unfinishedFromLastTime(let url):
            return url
        case .couldNotCreateFolder, .notEnoughDiskSpace, .couldNotCreateFile, .couldNotStartCapture, .noAudioCaptured:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .couldNotCreateFolder(let path):
            return "Wiretapper could not create the folder \(path)."
        case .notEnoughDiskSpace(let path):
            return "There isn't enough free disk space to record into \(path). Free up some space and try again."
        case .couldNotCreateFile(let status):
            return "Wiretapper could not create the recording file. (Error \(status))"
        case .couldNotStartCapture(let step, let status):
            return "Wiretapper could not start recording: \(step). (Error \(status))"
        case .noAudioCaptured:
            return "No audio was captured, so no file was saved."
        case .writeFailed(let url, let status):
            return "Recording stopped because writing to disk failed. "
                + "\(url.lastPathComponent) may be incomplete or may not play. (Error \(status))"
        case .diskAlmostFull(let url):
            return "Recording stopped because the disk is almost full. "
                + "Everything up to that point was saved as \(url.lastPathComponent)."
        case .fileSizeLimitReached(let url):
            return "Recording stopped because this file type can't be larger than 4 GB. "
                + "Everything up to that point was saved as \(url.lastPathComponent)."
        case .couldNotFinishFile(let url, let status):
            return "\(url.lastPathComponent) could not be finished and may not play. (Error \(status))"
        case .couldNotFinishInTime(let url):
            return "Wiretapper could not finish saving \(url.lastPathComponent), so it probably won't play. "
                + "Quit and reopen Wiretapper before recording again."
        case .outputDeviceChanged(let url):
            return "Recording stopped because your sound output changed. "
                + "Everything up to that point was saved as \(url.lastPathComponent)."
        case .unfinishedFromLastTime(let url):
            return "Wiretapper closed unexpectedly while recording. "
                + "\(url.lastPathComponent) was not finished and may not play."
        }
    }
}
