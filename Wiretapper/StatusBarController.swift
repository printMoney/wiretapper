import AppKit
import ServiceManagement

/// Controls the menu bar icon: how it looks and what happens when it is clicked.
final class StatusBarController: NSObject {
    /// The icon's slot in the macOS menu bar.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let recorder = SystemAudioRecorder()
    private let settings = AppSettings()
    /// True while waiting for the permission prompt, so extra clicks are ignored.
    private var isWaitingForPermission = false
    private var recordingStartDate: Date?
    private var elapsedTimer: Timer?

    override init() {
        super.init()

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        // Ask macOS to tell us about both left and right clicks.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        // Digits of equal width stop the icon from jiggling as the timer counts.
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        showIdleAppearance()
        createOutputFolder()
        warnAboutUnfinishedRecording()

        // If recording ends by itself, such as when the disk is almost full,
        // update the icon at once and explain what happened once it is saved.
        recorder.onStopping = { [weak self] in
            self?.showStoppedState()
        }
        recorder.onInterrupted = { [weak self] error in
            self?.forgetFinishedRecording()
            Notifier.shared.showProblem(error)
        }
    }

    // MARK: - Clicks

    /// Runs on every click, then decides between "toggle recording" and "open menu".
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }

        let isRightClick = event.type == .rightMouseUp
        let isControlClick = event.modifierFlags.contains(.control)

        if isRightClick || isControlClick {
            showMenu()
        } else {
            toggleRecording()
        }
    }

    /// Opens the dropdown. The menu is attached only while it is showing;
    /// otherwise macOS would open it on left-click too.
    private func showMenu() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Recording state

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecordingIfAllowed()
        }
    }

    private func startRecordingIfAllowed() {
        guard !isWaitingForPermission else { return }
        isWaitingForPermission = true

        AudioPermission.request { [weak self] granted in
            guard let self else { return }
            self.isWaitingForPermission = false

            if granted {
                self.startRecording()
            } else {
                self.showPermissionDeniedAlert()
            }
        }
    }

    private func startRecording() {
        Notifier.shared.requestPermission()

        do {
            try recorder.start(folder: settings.outputFolder, format: settings.format)
        } catch {
            Notifier.shared.showProblem(error)
            return
        }
        settings.unfinishedRecordingPath = recorder.currentFileURL?.path

        recordingStartDate = Date()
        showRecordingAppearance()

        // Check the clock often so the display never skips a second.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateElapsedTime()
        }
        // ".common" keeps the timer running while the dropdown menu is open.
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopRecording() {
        showStoppedState()
        recorder.stop { [weak self] result in
            self?.forgetFinishedRecording()
            switch result {
            case .success(let savedFile): Notifier.shared.showSaved(savedFile)
            case .failure(let error): Notifier.shared.showProblem(error)
            }
        }
    }

    /// Makes sure a recording in progress is saved properly when the app quits.
    func finishRecordingBeforeQuit() {
        guard recorder.isRecording else { return }
        switch recorder.stopAndWait() {
        case .success(let savedFile):
            settings.unfinishedRecordingPath = nil
            Notifier.shared.showSaved(savedFile)
        case .failure(let error):
            // A file that couldn't be finished stays remembered, so the next
            // launch can warn about it if this message doesn't get through.
            if case RecordingError.couldNotFinishInTime = error {} else {
                settings.unfinishedRecordingPath = nil
            }
            Notifier.shared.showProblem(error)
        }
        Notifier.shared.waitUntilDelivered()
    }

    /// Forgets a finished recording, unless a newer one has started since.
    private func forgetFinishedRecording() {
        if settings.unfinishedRecordingPath != recorder.currentFileURL?.path {
            settings.unfinishedRecordingPath = nil
        }
    }

    /// If Wiretapper crashed or was force quit while recording, say so now.
    private func warnAboutUnfinishedRecording() {
        guard let path = settings.unfinishedRecordingPath else { return }
        settings.unfinishedRecordingPath = nil
        guard FileManager.default.fileExists(atPath: path) else { return }
        Notifier.shared.showProblem(RecordingError.unfinishedFromLastTime(URL(fileURLWithPath: path)))
    }

    /// Puts the icon back to normal and stops the timer.
    private func showStoppedState() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartDate = nil
        showIdleAppearance()
    }

    private func updateElapsedTime() {
        guard let recordingStartDate else { return }

        let totalSeconds = Int(Date().timeIntervalSince(recordingStartDate))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        statusItem.button?.title = String(format: " %02d:%02d", minutes, seconds)
    }

    // MARK: - Messages

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Wiretapper can't record system audio"
        alert.informativeText = "Allow Wiretapper in System Settings > Privacy & Security > "
            + "Screen & System Audio Recording, under System Audio Recording Only. Then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            AudioPermission.openSystemSettings()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning

        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Icon appearance

    private func showIdleAppearance() {
        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Start recording")
        // A "template" image automatically adapts to light and dark menu bars.
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
    }

    private func showRecordingAppearance() {
        let redStyle = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Stop recording")?
            .withSymbolConfiguration(redStyle)
        image?.isTemplate = false
        statusItem.button?.image = image
        statusItem.button?.title = " 00:00"
    }

    // MARK: - Dropdown menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // We decide ourselves which items are clickable.
        menu.autoenablesItems = false

        let formatHeading = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatHeading.isEnabled = false
        menu.addItem(formatHeading)

        for format in RecordingFormat.allCases {
            let item = addItem(to: menu, title: format.menuTitle, action: #selector(formatChosen(_:)))
            item.representedObject = format.rawValue
            item.state = format == settings.format ? .on : .off
        }

        menu.addItem(.separator())

        let folderPath = (settings.outputFolder.path as NSString).abbreviatingWithTildeInPath
        addItem(to: menu, title: "Output folder: \(folderPath)", action: #selector(chooseOutputFolder))
        addItem(to: menu, title: "Open output folder", action: #selector(openOutputFolder))

        let launchItem = addItem(to: menu, title: "Launch at login", action: #selector(toggleLaunchAtLogin))
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())

        addItem(to: menu, title: "About", action: #selector(showAbout))
        addItem(to: menu, title: "Quit", action: #selector(quit))

        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func formatChosen(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let format = RecordingFormat(rawValue: rawValue) else { return }
        settings.format = format
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolder
        panel.prompt = "Choose"

        NSApp.activate()
        if panel.runModal() == .OK, let folder = panel.url {
            settings.outputFolder = folder
        }
    }

    @objc private func openOutputFolder() {
        createOutputFolder()
        NSWorkspace.shared.open(settings.outputFolder)
    }

    private func createOutputFolder() {
        try? FileManager.default.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
    }

    @objc private func toggleLaunchAtLogin() {
        let loginItem = SMAppService.mainApp
        do {
            if loginItem.status == .enabled {
                try loginItem.unregister()
            } else {
                try loginItem.register()
            }
            // macOS may want the user to approve this in System Settings.
            if loginItem.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            showAlert(title: "Launch at login could not be changed", message: error.localizedDescription)
        }
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "Records your Mac's internal audio.\nOpen source under the MIT License.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        // Menu bar apps are in the background, so bring the About box to the front.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
