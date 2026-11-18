# TapRecorder

TapRecorder is a small, open-source macOS menu bar app that records your Mac's internal audio to a file. It records what your Mac is playing and never records a microphone.

> **Screenshot:** add a screenshot of the menu bar app here.

## Features

- Left-click the menu bar icon to start or stop recording.
- Right-click or Control-click the icon to open the menu.
- See the elapsed time next to the icon while recording.
- Save recordings as:
  - M4A (AAC 320 kbps)
  - FLAC
  - WAV (24-bit)
  - AIFF (24-bit)
- Choose your output folder. The default is `~/Music/TapRecorder`.
- Get a notification when a recording is saved. Click it to show the file in Finder.
- Optionally start TapRecorder when you log in.

## Requirements

- macOS 14.4 or later
- Xcode 16 or later to build the app

## Build and run in Xcode

1. Download or clone this repository.
2. Double-click `TapRecorder.xcodeproj` to open it in Xcode.
3. At the top of the Xcode window, check that the scheme says **TapRecorder** and the destination says **My Mac**.
4. Click the **Play** button, or press **Command-R**.
5. Look for the small circle icon near the right side of your menu bar. TapRecorder has no Dock icon or main window.

## How permissions work

**System audio recording:** macOS asks for permission the first time you record. If you deny it, TapRecorder shows a button that opens System Settings. You can change it later in **System Settings > Privacy & Security > Screen & System Audio Recording**, under **System Audio Recording Only**.

**Notifications:** macOS asks whether TapRecorder can show notifications. If you turn them off, recording still works, and problems appear in an alert window instead.

**Microphone:** TapRecorder does not request microphone access and does not open any microphone.

Development builds are signed locally, so macOS may ask for system audio permission again after the code changes.

## Good to know

- WAV and AIFF files can't be larger than 4 GB, which is about 4 hours at 48 kHz. TapRecorder saves the recording and tells you if it reaches that limit.
- Recording stops and saves if your sound output device changes.
- M4A recordings above 48 kHz are converted to 48 kHz.
- Apps that replay another app's sound can make recordings echo. TapRecorder leaves out VolumeRocker for this reason. Other apps that work this way may need to be closed while recording.

## License

TapRecorder is released under the [MIT License](LICENSE). It uses only Apple's built-in frameworks and bundles no third-party code.
