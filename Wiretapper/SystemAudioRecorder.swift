import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing and streams it into a file.
///
/// How it works:
/// 1. A "process tap" listens to the sound apps send to the current output.
/// 2. A private "aggregate device" delivers that sound to this app. Its only
///    source is the tap, so a microphone can never be part of a recording.
/// 3. macOS calls our code many times a second with the next slice of sound.
final class SystemAudioRecorder {
    /// Called on the main thread the moment recording stops without the user
    /// asking, such as when the disk is almost full.
    var onStopping: (() -> Void)?
    /// Called on the main thread once that file is finished, explaining why it stopped.
    var onInterrupted: ((Error) -> Void)?

    private(set) var isRecording = false

    /// The file being recorded right now, if any.
    var currentFileURL: URL? { file?.url }

    /// Apps that replay another app's sound. Recording them as well would
    /// put the same sound in the file twice, which is heard as an echo.
    private static let excludedAppIDPrefixes = ["io.github.printmoney.VolumeRocker"]

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var excludedProcesses: [AudioObjectID] = []
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: RecordingFile?

    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var outputSampleRate: Float64 = 0
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var diskSpaceTimer: Timer?

    // These are shared with the audio thread. They are set up before capture
    // starts and read after it stops, so the two sides never collide.
    private let framesWritten = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let writeStatus = UnsafeMutablePointer<OSStatus>.allocate(capacity: 1)

    deinit {
        framesWritten.deallocate()
        writeStatus.deallocate()
    }

    // MARK: - Start

    func start(folder: URL, format recordingFormat: RecordingFormat) throws {
        guard !isRecording else { return }
        framesWritten.pointee = 0
        writeStatus.pointee = noErr

        do {
            outputDeviceID = try Self.defaultOutputDevice()
            outputSampleRate = try Self.sampleRate(of: outputDeviceID)
            let tapUID = try createTap()
            try createAggregateDevice(tapUID: tapUID)
            let format = try tapFormat()
            let newFile = try RecordingFile(folder: folder, format: recordingFormat, sourceFormat: format)
            file = newFile
            try startCapture(into: newFile, format: format)
            startWatchingOutputDevice()
            startWatchingDiskSpace(in: folder)
            isRecording = true
        } catch {
            // Undo whatever was set up, and remove the unused empty file.
            stopCapture()
            if let unusedFile = file {
                _ = unusedFile.finish(timeout: 5)
                try? FileManager.default.removeItem(at: unusedFile.url)
                file = nil
            }
            throw error
        }
    }

    /// Step 1: create a stereo tap of the apps playing to the current output
    /// device, leaving out apps that would double the sound. Sound keeps
    /// playing normally.
    private func createTap() throws -> String {
        let outputUID = try Self.deviceUID(of: outputDeviceID)
        excludedProcesses = Self.processesToExclude()
        let description = CATapDescription(excludingProcesses: excludedProcesses, deviceUID: outputUID, stream: 0)
        tapDescription = description
        description.name = "Wiretapper"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw RecordingError.couldNotStartCapture("the system audio tap was refused", status)
        }
        return description.uuid.uuidString
    }

    /// Step 2: wrap the tap in a private device that only this app can see.
    /// No hardware is added to this device on purpose. Headphones and audio
    /// interfaces can include microphones, and those must never be opened.
    private func createAggregateDevice(tapUID: String) throws {
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Wiretapper Capture",
            kAudioAggregateDeviceUIDKey: "io.github.printmoney.wiretapper.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID
            ]]
        ]

        let status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            throw RecordingError.couldNotStartCapture("the capture device could not be created", status)
        }
    }

    /// Asks the tap what format its sound arrives in, including the sample rate.
    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = Self.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw RecordingError.couldNotStartCapture("the audio format could not be read", status)
        }
        return format
    }

    /// Step 3: start receiving sound and pass each slice to the file.
    private func startCapture(into file: RecordingFile, format: AudioStreamBasicDescription) throws {
        // Interleaved sound arrives in one buffer. Otherwise each channel has its own.
        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let tapBufferCount = isInterleaved ? 1 : Int(format.mChannelsPerFrame)

        let bytesPerFrame = format.mBytesPerFrame
        let framesWritten = framesWritten
        let writeStatus = writeStatus

        // This block runs on a time-critical audio thread, so it must stay quick.
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard writeStatus.pointee == noErr else { return }

            // Safety check: accept only the exact shape of the tap's sound.
            // Anything else is ignored rather than written to the recording.
            guard Int(inputData.pointee.mNumberBuffers) == tapBufferCount else { return }

            let frameCount = inputData.pointee.mBuffers.mDataByteSize / bytesPerFrame
            guard frameCount > 0 else { return }

            let status = file.write(frameCount: frameCount, buffers: inputData)
            if status == noErr {
                framesWritten.pointee += Int64(frameCount)
            } else {
                writeStatus.pointee = status
                DispatchQueue.main.async { self?.handleWriteFailure() }
            }
        }

        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil, ioBlock)
        guard createStatus == noErr, ioProcID != nil else {
            throw RecordingError.couldNotStartCapture("the audio connection could not be created", createStatus)
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            throw RecordingError.couldNotStartCapture("the audio connection would not start", startStatus)
        }
    }

    // MARK: - Stop

    /// Stops recording at once, then finishes the file in the background so the
    /// menu bar never freezes. `completion` runs on the main thread.
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let capture = detachFile() else {
            completion(.failure(RecordingError.noAudioCaptured))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.finish(capture, timeout: 20)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Used while the app quits: stops and waits a few seconds for the file.
    func stopAndWait() -> Result<URL, Error> {
        guard let capture = detachFile() else { return .failure(RecordingError.noAudioCaptured) }
        return Self.finish(capture, timeout: 5)
    }

    /// What is needed to finish a file after its recording has stopped.
    private struct StoppedCapture {
        let file: RecordingFile
        let framesWritten: Int64
        let writeStatus: OSStatus
    }

    private func detachFile() -> StoppedCapture? {
        stopCapture()
        isRecording = false

        guard let file else { return nil }
        self.file = nil
        return StoppedCapture(file: file, framesWritten: framesWritten.pointee, writeStatus: writeStatus.pointee)
    }

    /// Finishes the file and decides whether it was saved properly.
    private static func finish(_ capture: StoppedCapture, timeout: TimeInterval) -> Result<URL, Error> {
        let url = capture.file.url
        guard let finishStatus = capture.file.finish(timeout: timeout) else {
            return .failure(RecordingError.couldNotFinishInTime(url))
        }
        if capture.writeStatus != noErr {
            if capture.file.hasReachedSizeLimit(framesWritten: capture.framesWritten) {
                return .failure(RecordingError.fileSizeLimitReached(url))
            }
            return .failure(RecordingError.writeFailed(url, capture.writeStatus))
        }
        if finishStatus != noErr {
            return .failure(RecordingError.couldNotFinishFile(url, finishStatus))
        }
        if capture.framesWritten == 0 {
            try? FileManager.default.removeItem(at: url)
            return .failure(RecordingError.noAudioCaptured)
        }
        return .success(url)
    }

    /// Takes everything apart in the reverse order it was built.
    private func stopCapture() {
        stopWatchingOutputDevice()
        diskSpaceTimer?.invalidate()
        diskSpaceTimer = nil

        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDescription = nil
        excludedProcesses = []
    }

    // MARK: - Problems during recording

    /// Stops without the user asking and reports why. `reason` explains a
    /// file that was saved properly; other problems are reported as they are.
    private func stopByItself(reason: @escaping (URL) -> RecordingError) {
        guard isRecording else { return }
        onStopping?()
        stop { [weak self] result in
            switch result {
            case .success(let url): self?.onInterrupted?(reason(url))
            case .failure(let error): self?.onInterrupted?(error)
            }
        }
    }

    private func handleWriteFailure() {
        stopByItself { RecordingError.writeFailed($0, noErr) }
    }

    /// The capture is tied to the current speakers, so if they change we save
    /// what we have rather than keep a timer running over a silent recording.
    private func handleOutputChange() {
        guard isRecording else { return }
        let currentDevice = try? Self.defaultOutputDevice()
        let currentRate = try? Self.sampleRate(of: outputDeviceID)
        guard currentDevice != outputDeviceID || currentRate != outputSampleRate else { return }

        stopByItself(reason: RecordingError.outputDeviceChanged)
    }

    /// Checks free space every few seconds and stops before the disk is full.
    private func startWatchingDiskSpace(in folder: URL) {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let freeSpace = RecordingFile.availableSpace(in: folder),
                  freeSpace < RecordingFile.minimumFreeSpace else { return }
            self?.stopByItself(reason: RecordingError.diskAlmostFull)
        }
        RunLoop.main.add(timer, forMode: .common)
        diskSpaceTimer = timer
    }

    /// If an excluded app starts while recording, leave it out from then on.
    private func handleProcessListChange() {
        guard isRecording, let description = tapDescription else { return }
        let currentProcesses = Self.processesToExclude()
        guard currentProcesses != excludedProcesses else { return }

        description.processes = currentProcesses
        var address = Self.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description)
        let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
        if AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &reference) == noErr {
            excludedProcesses = currentProcesses
        }
    }

    private func startWatchingOutputDevice() {
        let processListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleProcessListChange() }
        var processAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processAddress, .main, processListener)
        processListListener = processListener

        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleOutputChange() }
        var deviceAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, .main, deviceListener)
        outputDeviceListener = deviceListener

        let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleOutputChange() }
        var rateAddress = Self.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(outputDeviceID, &rateAddress, .main, rateListener)
        sampleRateListener = rateListener
    }

    private func stopWatchingOutputDevice() {
        if let processListListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, processListListener)
            self.processListListener = nil
        }
        if let outputDeviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputDeviceListener)
            self.outputDeviceListener = nil
        }
        if let sampleRateListener {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(outputDeviceID, &address, .main, sampleRateListener)
            self.sampleRateListener = nil
        }
    }

    // MARK: - Questions for Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Finds the running audio processes that belong to excluded apps.
    private static func processesToExclude() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processes) == noErr else { return [] }

        return processes.filter { process in
            guard let appID = bundleID(of: process) else { return false }
            return excludedAppIDPrefixes.contains { appID.hasPrefix($0) }
        }.sorted()
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundleID) == noErr else { return nil }
        return bundleID?.takeRetainedValue() as String?
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw RecordingError.couldNotStartCapture("no sound output device was found", status)
        }
        return deviceID
    }

    private static func sampleRate(of deviceID: AudioObjectID) throws -> Float64 {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr else {
            throw RecordingError.couldNotStartCapture("the sample rate could not be read", status)
        }
        return rate
    }

    private static func deviceUID(of deviceID: AudioObjectID) throws -> String {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else {
            throw RecordingError.couldNotStartCapture("the sound output device could not be identified", status)
        }
        return uid.takeRetainedValue() as String
    }
}
