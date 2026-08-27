# Screenshot Clipboard for macOS

Screenshot Clipboard watches the macOS general pasteboard for PNG images. It
keeps the native screenshot preview, copies screenshots to the clipboard
immediately, saves a canonical copy, and organizes a hard link by the source
application.

## Features

- Works with the native `Shift-Command-4` and `Shift-Command-5` screenshot flows.
- Saves to `~/Desktop/Ekran Görüntüleri/Mac Ekran Görüntüleri/` by default.
- Keeps a general screenshot folder and an `Uygulamalar/<App>` folder.
- Uses the source application name in the file name.
- Shows up to three previews with compact and card views.
- Supports clipboard paste, file drag, context actions, OCR, and right-swipe dismissal.
- Adds right-click actions to send a selected screenshot to a new ChatGPT or Gemini conversation for Turkish translation.
- Validates PNG size, dimensions, and decodability before saving.
- Uses no network connection and stores no credentials.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools (`swiftc`, `codesign`, `plutil`, and `launchctl`).

## Install

```bash
./Scripts/install.sh
```

The app runs as a per-user LaunchAgent and starts again after login. macOS may
ask for access to the Desktop folder on the first screenshot. Allow it so the
app can write the configured screenshot folders.

## Uninstall

```bash
./Scripts/uninstall.sh
```

The uninstall script removes the app and LaunchAgent. It does not delete saved
screenshots.

## Development checks

```bash
./Scripts/check.sh
```

The build uses a local ad-hoc signature so the designated requirement remains
stable across rebuilds on one Mac. This is not Apple Developer signing or
notarization. A distributable `.dmg` should be signed and notarized separately.

## Privacy and scope

The app polls the general pasteboard for PNG data and reads the frontmost app
name to choose a folder. The helper itself does not make network calls.
Screenshots may contain private information; keep the output folders local and
do not commit them to a repository.

The right-click translation actions use the installed ChatGPT and Gemini
desktop applications, not API keys or account credentials. They require
Accessibility permission for Screenshot Clipboard so macOS can activate the
target app, paste the selected image and translation prompt, and submit it.
Translation starts only after an explicit right-click action; screenshots are
not sent automatically in the background. The selected target application may
send the image to its own online service. If the target app has no accessible
message field, the app stops without pasting or submitting the screenshot.

The current implementation uses a fixed bundle identifier
`com.zekiakgul.screenshot-clipboard`. Forks should change the identifier in
`Resources/Info.plist`, the LaunchAgent template, and the build/install scripts
if they need an independent installation identity.
