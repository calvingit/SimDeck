# AVD MenuBar

English | [简体中文](README_zh.md)

A native macOS menu bar app for managing local Android Virtual Devices (AVDs) and previewing Android devices connected over ADB.

![AVD MenuBar demo: menu bar panel and main window preview](docs/demo-en.gif)

[Requirements](#requirements) · [Build and run](#build-and-run) · [Contributing](CONTRIBUTING.md)

## Features

- Devices grouped by running state, with Android version and API level.
- Start, shut down, restart, cold boot, wipe data, delete, and rename AVDs.
- Live preview with touch input and Back/Home/Recents/Power/Volume buttons.
- Named snapshots: save, load, and delete.
- Copy device details or launch commands; open the AVD folder or emulator log.
- Developer tools: adb shell, logcat, screenshot, Android Studio.
- Create, rename, and move AVDs.
- Pin the panel or frequently used AVDs; optional launch at login.

## Requirements

- macOS 14 or later.
- Android SDK Command-line Tools, Android Emulator, and Platform-Tools.
- JDK 17 or later for `avdmanager`.

## Build and run

```bash
./scripts/build-app.sh
open build/AVDMenuBar.app
```

The build is ad-hoc signed. GitHub Actions builds the Apple Silicon version for every push and publishes a DMG for version tags; see [Releases](https://github.com/calvingit/AVDMenuBar/releases).

On first launch, macOS may ask for access to the Android SDK or removable volumes. Grant it to list and manage AVDs. The app runs in the menu bar only.

## Settings

- **Tool paths**: detected automatically, or choose avdmanager / emulator / adb manually.
- **Language**: System, Simplified Chinese, or English; restart to apply.
- **Appearance**: System, Light, or Dark.
- **Launch at Login**.

## Notes

- Deleting an AVD and wiping its data both require confirmation.
- Wiping data keeps the old snapshots as `snapshots.pre-wipe-<time>`.
- The preview uses an ADB video stream and falls back to screenshots when the stream is unavailable.
- Only named snapshots are listed; saving and loading require a running emulator.
- Emulator logs are written to `~/Library/Logs/AVDMenuBar/<AVD name>.log`.

## Project docs

- [Development guidelines](AGENTS.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)
- [Security reports](SECURITY.md)

## License

MIT is planned. The copyright holder is still being confirmed, and no license file has been added yet.
