import XCTest
@testable import AVDCore

final class AVDListParserTests: XCTestCase {
    private let sample = """
    Available Android Virtual Devices:
        Name: Pixel_7a
      Device: pixel_7a (Google)
        Path: /Users/me/.android/avd/Pixel_7a.avd
      Target: Google Play (Google Inc.)
              Based on: Android 14.0 ("UpsideDownCake") Tag/ABI: google_apis_playstore/arm64-v8a
        Skin: pixel_7a
      Sdcard: 4G
    ---------
        Name: Android_9.0_Phone
      Device: medium_phone (Generic)
        Path: /Users/me/.android/avd/Android_9.0_Phone.avd
      Target: Google ARM64-V8a Play (Google Inc.)
              Based on: Android 9.0 ("Pie") Tag/ABI: google_apis_playstore/arm64-v8a
      Sdcard: 512M
    ---------
    """

    func testParsesAllFields() {
        let avds = AVDListParser.parse(sample)
        XCTAssertEqual(avds.count, 2)

        let pixel = avds[0]
        XCTAssertEqual(pixel.name, "Pixel_7a")
        XCTAssertEqual(pixel.path, "/Users/me/.android/avd/Pixel_7a.avd")
        XCTAssertEqual(pixel.deviceName, "pixel_7a")
        XCTAssertEqual(pixel.deviceManufacturer, "Google")
        XCTAssertEqual(pixel.androidVersion, "14.0")
        XCTAssertEqual(pixel.codename, "UpsideDownCake")
        XCTAssertEqual(pixel.abi, "arm64-v8a")
        XCTAssertEqual(pixel.tag, "google_apis_playstore")
        XCTAssertEqual(pixel.skin, "pixel_7a")
        XCTAssertEqual(pixel.sdcard, "4G")

        let phone = avds[1]
        XCTAssertEqual(phone.name, "Android_9.0_Phone")
        XCTAssertEqual(phone.deviceName, "medium_phone")
        XCTAssertEqual(phone.androidVersion, "9.0")
        XCTAssertNil(phone.skin)
        XCTAssertEqual(phone.sdcard, "512M")
    }

    func testEmptyOutput() {
        XCTAssertTrue(AVDListParser.parse("Available Android Virtual Devices:\n").isEmpty)
        XCTAssertTrue(AVDListParser.parse("").isEmpty)
    }

    func testMissingPathDropsBlock() {
        let output = """
        Available Android Virtual Devices:
            Name: Broken
          Device: pixel (Google)
        """
        XCTAssertTrue(AVDListParser.parse(output).isEmpty)
    }

    func testRunningTitleSummary() {
        var avd = AVD(
            name: "Pixel_7a",
            path: "/tmp/Pixel_7a.avd",
            deviceName: "pixel_7a",
            androidVersion: "14.0",
            abi: "arm64-v8a"
        )
        XCTAssertEqual(avd.summary, "Android 14.0 · arm64-v8a · pixel_7a")
        avd.apiLevel = 34
        XCTAssertEqual(avd.summary, "Android 14.0 (API 34) · arm64-v8a · pixel_7a")
    }
}

final class ADBDevicesParserTests: XCTestCase {
    func testParsesDevicesAndFiltersMessages() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        emulator-5556          offline
        adb: no devices/emulators found
        """
        let devices = ADBDevicesParser.parse(output)
        XCTAssertEqual(devices, [
            ADBDevice(serial: "emulator-5554", state: "device"),
            ADBDevice(serial: "emulator-5556", state: "offline")
        ])
        XCTAssertTrue(devices.allSatisfy(\.isEmulator))
    }

    func testNoDevices() {
        XCTAssertTrue(ADBDevicesParser.parse("List of devices attached\n\n").isEmpty)
    }
}

final class AVDConfigTests: XCTestCase {
    func testTargetAPILevel() {
        let text = """
        AvdId=Pixel_7a
        target=android-34
        """
        XCTAssertEqual(AVDConfig.apiLevel(fromINI: text), 34)
    }

    func testSystemImageAPILevel() {
        let text = "image.sysdir.1=system-images;android-33;google_apis;arm64-v8a/"
        XCTAssertEqual(AVDConfig.apiLevel(fromINI: text), 33)
    }

    func testSlashSeparatedSystemImage() {
        let text = "image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/"
        XCTAssertEqual(AVDConfig.apiLevel(fromINI: text), 35)
    }

    func testNoAPILevel() {
        XCTAssertNil(AVDConfig.apiLevel(fromINI: "AvdId=Test\nabi.type=arm64-v8a\n"))
    }
}

final class EmulatorArgumentsTests: XCTestCase {
    func testNormalStart() {
        XCTAssertEqual(
            EmulatorController.launchArguments(avdName: "Pixel_7a", mode: .normal),
            ["-avd", "Pixel_7a"]
        )
    }

    func testColdBoot() {
        XCTAssertEqual(
            EmulatorController.launchArguments(avdName: "Pixel_7a", mode: .coldBoot),
            ["-avd", "Pixel_7a", "-no-snapshot-load"]
        )
    }

    func testWipeDataUsesManualDeletion() {
        XCTAssertEqual(
            EmulatorController.launchArguments(avdName: "Pixel_7a", mode: .wipeData),
            ["-avd", "Pixel_7a", "-no-snapshot-load"]
        )
        XCTAssertTrue(EmulatorController.wipeFileNames.contains("userdata-qemu.img"))
        XCTAssertTrue(EmulatorController.wipeFileNames.contains("cache.img"))
        XCTAssertFalse(EmulatorController.wipeFileNames.contains("snapshots"))
        XCTAssertFalse(EmulatorController.wipeFileNames.contains("userdata.img"))
    }
}

final class CommandRunnerTests: XCTestCase {
    func testCapturesStdout() throws {
        let result = try CommandRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "hello\n")
    }

    func testFailureDetailFallsBackToStdout() {
        let result = CommandResult(
            status: 1,
            stdout: "This tool requires JDK 17 or later.\n",
            stderr: ""
        )
        XCTAssertTrue(result.failureDetail.contains("JDK 17"))
    }

    func testPassesStandardInput() throws {
        let result = try CommandRunner.run(
            URL(fileURLWithPath: "/bin/cat"),
            [],
            input: "hello\n",
            timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "hello\n")
    }
}

final class ToolLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVDMenuBarTests-\(UUID().uuidString)")
        root = base
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("cmdline-tools/latest/bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("emulator"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("platform-tools"),
            withIntermediateDirectories: true
        )
        try makeExecutable(base.appendingPathComponent("cmdline-tools/latest/bin/avdmanager"))
        try makeExecutable(base.appendingPathComponent("emulator/emulator"))
        try makeExecutable(base.appendingPathComponent("platform-tools/adb"))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testDerivesSDKRootFromAVDManagerPath() throws {
        let tools = try ToolLocator.resolve(
            avdmanagerOverride: root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path,
            environment: [:]
        )
        XCTAssertEqual(
            tools.sdkRoot?.resolvingSymlinksInPath().path,
            root.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(tools.emulator?.lastPathComponent, "emulator")
        XCTAssertEqual(tools.adb?.lastPathComponent, "adb")
    }

    func testInvalidOverrideThrows() {
        XCTAssertThrowsError(
            try ToolLocator.resolve(
                avdmanagerOverride: "/definitely/not/here/avdmanager",
                environment: [:]
            )
        ) { error in
            guard case ToolPathError.invalidOverride(let tool, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "avdmanager")
        }
    }

    func testEnvironmentContainsSDKAndJavaPaths() throws {
        let tools = try ToolLocator.resolve(
            avdmanagerOverride: root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path,
            environment: [:]
        )
        let environment = ToolEnvironment.make(tools: tools, base: [:])
        XCTAssertEqual(environment["ANDROID_HOME"], tools.sdkRoot?.path)
        XCTAssertEqual(environment["ANDROID_SDK_ROOT"], tools.sdkRoot?.path)
        XCTAssertTrue(environment["PATH"]?.contains("/platform-tools") == true)
    }

    func testPathEntriesAreSearchCandidates() {
        let candidates = ToolLocator.autoAVDManagerCandidates(
            environment: ["PATH": "/custom/bin:/usr/bin:/bin"],
            files: .default
        )
        XCTAssertTrue(candidates.contains("/custom/bin/avdmanager"))
        XCTAssertTrue(candidates.contains("/usr/bin/avdmanager"))
    }

    func testSymlinkedAVDManagerDerivesSDKRoot() throws {
        let linkDirectory = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        let link = linkDirectory.appendingPathComponent("avdmanager")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent(
                "cmdline-tools/latest/bin/avdmanager"
            )
        )

        let tools = try ToolLocator.resolve(avdmanagerOverride: link.path, environment: [:])
        XCTAssertEqual(
            tools.sdkRoot?.resolvingSymlinksInPath().path,
            root.resolvingSymlinksInPath().path
        )
        XCTAssertNotNil(tools.emulator)
        XCTAssertNotNil(tools.adb)
    }

    private func makeExecutable(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

final class H264AnnexBParserTests: XCTestCase {
/// 生成的 NAL 实际长度：1 字节头 + 数据 + 3 字节转义序列。
    private func expectedNALSize(_ size: Int) -> Int {
        var length = 1
        for i in 0..<(size - 1) {
            length += 1
            if i % 97 == 96 {
                length += 3
            }
        }
        return length
    }


    /// 合成 Annex-B 流（含 4 字节起始码、跨 chunk 大 NAL、仿真防起始码转义），
    /// 按 1024 字节分块喂入，验证 NAL 完整提取。
    func testExtractsAllNALsAcrossChunks() throws {
        func nal(_ type: UInt8, size: Int) -> Data {
            var body = Data([type])
            for i in 0..<(size - 1) {
                body.append(UInt8((i * 7) % 251))
                // 每 97 字节插入 00 00 03 转义序列，模拟真实码流
                if i % 97 == 96 {
                    body.append(contentsOf: [0x00, 0x00, 0x03])
                }
            }
            return body
        }

        var stream = Data()
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        stream.append(nal(0x67, size: 19))          // SPS
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        stream.append(nal(0x68, size: 6))           // PPS
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        stream.append(nal(0x65, size: 9000))        // IDR（跨多个 chunk）
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        stream.append(nal(0x41, size: 1200))        // 非 IDR 切片
        stream.append(contentsOf: [0x00, 0x00, 0x01]) // 3 字节起始码
        stream.append(nal(0x41, size: 1200))
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // 末尾起始码，触发最后一个 NAL 结算

        var parser = H264AnnexBParser()
        var counts: [UInt8: Int] = [:]
        var sizes: [UInt8: Int] = [:]
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 1024, stream.count)
            for nal in parser.extract(stream.subdata(in: offset..<end)) {
                let type = nal[0] & 0x1F
                counts[type, default: 0] += 1
                sizes[type] = nal.count
            }
            offset = end
        }

        XCTAssertEqual(counts[7], 1)   // SPS
        XCTAssertEqual(counts[8], 1)   // PPS
        XCTAssertEqual(counts[5], 1)   // IDR
        XCTAssertEqual(counts[1], 2)   // 非 IDR 切片
        XCTAssertEqual(sizes[7], expectedNALSize(19))
        XCTAssertEqual(sizes[5], expectedNALSize(9000))
        XCTAssertEqual(sizes[1], expectedNALSize(1200))
    }
}
