import AudioToolbox
import Foundation

/// An audio file on disk that receives sound while recording is in progress.
final class RecordingFile {
    let url: URL
    private let format: RecordingFormat
    private let channelCount: Int64
    private let audioFile: ExtAudioFileRef

    /// Creates a new, empty audio file.
    /// - Parameter sourceFormat: the format of the sound we will be handed.
    init(folder: URL, format: RecordingFormat, sourceFormat: AudioStreamBasicDescription) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecordingError.couldNotCreateFolder(folder.path)
        }

        var fileFormat = try Self.fileDescription(
            for: format,
            sampleRate: sourceFormat.mSampleRate,
            channels: sourceFormat.mChannelsPerFrame
        )
        let fileURL = Self.unusedFileURL(in: folder, fileExtension: format.fileExtension)

        // Flags of 0 mean "fail rather than replace an existing file".
        var createdFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            fileURL as CFURL, Self.fileType(for: format), &fileFormat, nil, 0, &createdFile
        )
        guard createStatus == noErr, let createdFile else {
            throw RecordingError.couldNotCreateFile(createStatus)
        }

        // Tell the file what we will hand it, so it converts to 24-bit for us.
        var source = sourceFormat
        var setupStatus = ExtAudioFileSetProperty(
            createdFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &source
        )
        if setupStatus == noErr, format == .m4a {
            setupStatus = Self.useConstantAACBitRate(on: createdFile)
        }
        // This first empty write prepares the background writer.
        if setupStatus == noErr {
            setupStatus = ExtAudioFileWriteAsync(createdFile, 0, nil)
        }
        guard setupStatus == noErr else {
            ExtAudioFileDispose(createdFile)
            try? FileManager.default.removeItem(at: fileURL)
            throw RecordingError.couldNotCreateFile(setupStatus)
        }

        url = fileURL
        self.format = format
        channelCount = Int64(sourceFormat.mChannelsPerFrame)
        audioFile = createdFile
    }

    /// True if this much sound has filled a WAV or AIFF file to its 4 GB limit.
    func hasReachedSizeLimit(framesWritten: Int64) -> Bool {
        let bytesPerChannel: Int64 = 3 // 24 bits = 3 bytes.
        let audioBytes = framesWritten * channelCount * bytesPerChannel
        return format.hasFourGigabyteLimit && audioBytes >= 4_290_000_000
    }

    private static func fileType(for format: RecordingFormat) -> AudioFileTypeID {
        switch format {
        case .wav: return kAudioFileWAVEType
        case .aiff: return kAudioFileAIFFType
        case .flac: return kAudioFileFLACType
        case .m4a: return kAudioFileM4AType
        }
    }

    /// Sets the M4A encoder to a constant 320 kbps, or the closest rate below
    /// that if the current sample rate can't reach it.
    private static func useConstantAACBitRate(on file: ExtAudioFileRef) -> OSStatus {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        var status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter)
        guard status == noErr, let converter else { return status }

        var constantMode = UInt32(kAudioCodecBitRateControlMode_Constant)
        status = AudioConverterSetProperty(
            converter, kAudioCodecPropertyBitRateControlMode, UInt32(MemoryLayout<UInt32>.size), &constantMode
        )
        guard status == noErr else { return status }

        // Ask which bit rates the encoder offers, then pick the best one.
        var listSize: UInt32 = 0
        status = AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &listSize, nil)
        guard status == noErr else { return status }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(), count: Int(listSize) / MemoryLayout<AudioValueRange>.size
        )
        status = AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &listSize, &ranges)
        guard status == noErr else { return status }

        let targetBitRate: Float64 = 320_000
        guard let bestBitRate = ranges.map(\.mMaximum).filter({ $0 <= targetBitRate }).max() else {
            return kAudioConverterErr_PropertyNotSupported
        }
        var bitRate = UInt32(bestBitRate)
        status = AudioConverterSetProperty(
            converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate
        )
        guard status == noErr else { return status }

        // Tell the file to start using the encoder settings we just changed.
        var noExtraSettings: OpaquePointer?
        return ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<OpaquePointer?>.size), &noExtraSettings
        )
    }

    /// Describes how sound is stored inside each kind of file.
    private static func fileDescription(
        for format: RecordingFormat,
        sampleRate: Float64,
        channels: UInt32
    ) throws -> AudioStreamBasicDescription {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = sampleRate
        description.mChannelsPerFrame = channels

        switch format {
        case .wav, .aiff:
            let bytesPerFrame = 3 * channels // 24 bits = 3 bytes per channel.
            description.mFormatID = kAudioFormatLinearPCM
            description.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            if format == .aiff {
                description.mFormatFlags |= kAudioFormatFlagIsBigEndian // AIFF stores bytes in the opposite order.
            }
            description.mBytesPerPacket = bytesPerFrame
            description.mFramesPerPacket = 1
            description.mBytesPerFrame = bytesPerFrame
            description.mBitsPerChannel = 24

        case .flac:
            description.mFormatID = kAudioFormatFLAC
            description.mFormatFlags = kAppleLosslessFormatFlag_24BitSourceData
            // Ask macOS to fill in the remaining details of its FLAC encoder.
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &description)
            guard status == noErr else { throw RecordingError.couldNotCreateFile(status) }

        case .m4a:
            // AAC is designed for sample rates up to 48 kHz. Higher rates are converted.
            description.mSampleRate = min(sampleRate, 48_000)
            description.mFormatID = kAudioFormatMPEG4AAC
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &description)
            guard status == noErr else { throw RecordingError.couldNotCreateFile(status) }
        }
        return description
    }

    /// Queues sound to be saved by a background thread. This returns quickly,
    /// which matters because it is called from the time-critical audio thread.
    func write(frameCount: UInt32, buffers: UnsafePointer<AudioBufferList>) -> OSStatus {
        ExtAudioFileWriteAsync(audioFile, frameCount, buffers)
    }

    /// Saves anything still queued and finishes the file. Call this exactly once.
    func close() -> OSStatus {
        ExtAudioFileDispose(audioFile)
    }

    /// Builds "Recording 2026-11-18 at 14.32.05.wav", adding " (2)" and so on
    /// if that name is already taken.
    private static func unusedFileURL(in folder: URL, fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "Recording \(formatter.string(from: Date()))"

        var candidate = folder.appendingPathComponent("\(baseName).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) (\(number)).\(fileExtension)")
            number += 1
        }
        return candidate
    }
}
