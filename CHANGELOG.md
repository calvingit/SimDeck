# Changelog

## Unreleased

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
