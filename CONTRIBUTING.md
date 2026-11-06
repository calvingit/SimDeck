# Contributing

Bug reports, documentation improvements, and code contributions are welcome. Discuss the expected behavior with the maintainers before changing device operations, data safety, or system permissions.

## Local development

Use macOS 14 or later and an Xcode toolchain with Swift 5.9 or later. Building the app and running tests with mock tools do not require the Android SDK. To manage actual AVDs, follow the [requirements](README.md#requirements).

```bash
swift build
swift test --skip IntegrationTests
AVD_MOCK_E2E=1 swift test --skip IntegrationTests
```

For changes to the menu bar, preview, settings, or bundled resources, run `./scripts/build-app.sh` and verify the affected behavior in the macOS app. For text changes, check English and Simplified Chinese for clipping and correct placeholder substitution.

Run real SDK and device tests separately. The H.264 tests can briefly record the screen of a detected device, so connect only a dedicated test device:

```bash
AVD_INTEGRATION=1 swift test --filter IntegrationTests
```

## Reporting issues and submitting changes

- Include the app version or build source, macOS version, device type, reproduction steps, and expected and actual behavior. Share only relevant log excerpts, with serial numbers, usernames, local paths, and other sensitive data removed.
- In a pull request, explain the problem, what users will see, how you verified the change, and what remains untested. Call out changes to startup, shutdown, snapshots, or data wiping.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
