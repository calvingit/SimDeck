# SimDeck development guidelines

Use Chinese when communicating with the user. Lead with the result, then give the evidence and next step. Follow existing conventions for identifiers, comments, and commit messages. Preserve unrelated user changes and avoid incidental refactors, formatting changes, or dependency upgrades.

## Project layout

- `Sources/SimDeck/`: SwiftUI views, AppKit windows and menu bar, app state, and action routing.
- `Sources/SimDeckCore/`: Android SDK tool discovery, command execution, AVD and snapshot management, and ADB video streaming.
- `Tests/SimDeckCoreTests/`: core tests, mock tool tests, and real SDK and device tests.
- `scripts/build-app.sh`: builds with SwiftPM and replaces the generated bundle at `build/SimDeck.app`.
- [README.md](README.md) and [README_zh.md](README_zh.md): user-facing behavior and installation.

## Changes and verification

- Update both `en.lproj` and `zh-Hans.lproj` in `Sources/SimDeckCore/Localization` when changing user-facing text. Keep keys and format placeholders in sync. macOS permission descriptions live in `Resources/*/InfoPlist.strings`.
- Keep AVD names, ADB serials, and process IDs distinct. Preserve stale-serial checks and confirmation prompts for destructive actions such as deletion and data wiping.
- Run `swift test --skip IntegrationTests` for routine checks. Run `AVD_MOCK_E2E=1 swift test --skip IntegrationTests` when changing command execution or device operations. Real-device tests can start screen recording; run them separately as described in [CONTRIBUTING.md](CONTRIBUTING.md).
- For UI, signing, or resource packaging changes, build and inspect the resulting app as appropriate. State what was verified; a successful compile does not verify UI or device behavior.
- Review the scope before handing off. Push, rewrite history, or run destructive Git commands only when explicitly authorized. Ask before removing unrelated files, modifying real device data or production systems, performing bulk replacements across files, or installing or upgrading dependencies.
