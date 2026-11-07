# Changelog

## 1.2

- Added windowless preview for Android emulators: start an AVD without the emulator window (software rendering, quick-boot snapshots are never saved), with live preview and touch input over ADB, on-demand switching to a regular window ("Open in Window"), and automatic shutdown of app-started windowless instances when the app quits.
- The main window device list can now be hidden or shown via the toolbar sidebar button or ⌘⌥S; a minimal app menu (Settings ⌘, / Quit ⌘Q / Toggle Sidebar ⌘⌥S) is shown while the main window is active.
- Menu bar panel: retitled to SimDeck, tabs now show running device counts, and the panel pin button was removed (the panel always dismisses on outside clicks).
- User-facing "AVD" wording was replaced with "emulator" across UI strings; device rows now show "Android <version> · API <level>" instead of an "AVD" prefix.

## 1.1

- Renamed the project to SimDeck (formerly AVDMenuBar). The bundle identifier is now `local.simdeck`, so macOS treats an updated install as a new app: permissions and preferences reset on first launch.
- Added iOS simulator support (requires Xcode): list, boot/shutdown/restart, create/rename/delete/erase with confirmation dialogs, screenshot preview with automatic fallback, simulator logs in a terminal, and app management (install .app, launch/terminate/uninstall by bundle id, open URL).
- Added a create wizard for iOS simulators that filters device types by the selected runtime's supported device types.
- Added optional bundled baguette for the enhanced tier (live H.264 preview, touch and hardware-key input). Place the binary in `Vendor/baguette/` before building, with its checksum recorded in `checksums.txt` — see README.
- Settings now show the developer directory and baguette status, with a baguette path override.
- Added English and Simplified Chinese project documentation, with demos in both languages.
- Added GitHub Actions packaging and automatic GitHub Releases for pushed tags, with an Apple Silicon DMG installer.

## 1.0

- Added System, Simplified Chinese, and English language options. Changes take effect after reopening the app.
- Added space around the emulator preview and a background that adapts to light and dark appearance.
- Left-click the menu bar icon to open the device panel. Right-click or Control-click to open the Quit menu.
- Added development guidelines, a contribution guide, and a security reporting policy.
