import XCTest
@testable import SimDeckCore

/// 用假的 avdmanager / emulator / adb 脚本验证进程生命周期与命令参数。
/// 默认跳过；运行：AVD_MOCK_E2E=1 swift test --filter MockE2ETests
final class MockE2ETests: XCTestCase {
    private var root: URL!
    private var avdName: String!
    private var avdDirectory: URL!
    private var recordFile: URL!
    private var tools: ToolPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["AVD_MOCK_E2E"] == "1" else {
            throw XCTSkip("设置 AVD_MOCK_E2E=1 后运行")
        }

        avdName = "MockAVD_\(UUID().uuidString.prefix(6))"
        // 路径故意包含空格，覆盖 ps 参数被空格切分的场景。
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimDeckMock-\(UUID().uuidString) With Space")
        avdDirectory = root.appendingPathComponent("avd/\(avdName!).avd")
        recordFile = root.appendingPathComponent("record.txt")

        let files = FileManager.default
        try files.createDirectory(at: avdDirectory, withIntermediateDirectories: true)
        try files.createDirectory(
            at: root.appendingPathComponent("sdk/cmdline-tools/latest/bin"),
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: root.appendingPathComponent("sdk/emulator"),
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: root.appendingPathComponent("sdk/platform-tools"),
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: avdDirectory.appendingPathComponent("snapshots/default_boot"),
            withIntermediateDirectories: true
        )

        try writeScript(
            at: root.appendingPathComponent("sdk/cmdline-tools/latest/bin/avdmanager"),
            contents: avdmanagerScript()
        )
        try writeScript(
            at: root.appendingPathComponent("sdk/emulator/emulator"),
            contents: sleepingEmulatorScript()
        )
        try writeScript(
            at: root.appendingPathComponent("sdk/platform-tools/adb"),
            contents: adbScript()
        )

        for name in [
            "userdata-qemu.img",
            "userdata-qemu.img.qcow2",
            "cache.img",
            "cache.img.qcow2",
            "userdata.img"
        ] {
            files.createFile(
                atPath: avdDirectory.appendingPathComponent(name).path,
                contents: Data("mock".utf8)
            )
        }
        files.createFile(
            atPath: avdDirectory.appendingPathComponent("snapshots/default_boot/snapshot.pb").path,
            contents: Data("snapshot".utf8)
        )
        try files.createDirectory(
            at: avdDirectory.appendingPathComponent("snapshots/named_snapshot"),
            withIntermediateDirectories: true
        )
        try "target=android-30\n".write(
            to: avdDirectory.appendingPathComponent("config.ini"),
            atomically: true,
            encoding: .utf8
        )

        tools = try ToolLocator.resolve(
            avdmanagerOverride: root.appendingPathComponent(
                "sdk/cmdline-tools/latest/bin/avdmanager"
            ).path,
            environment: [:]
        )
    }

    override func tearDownWithError() throws {
        if let tools, let avdName, let root {
            let controller = EmulatorController(
                tools: tools,
                logDirectory: root.appendingPathComponent("logs")
            )
            if let pid = controller.findEmulatorPID(avdName: avdName) {
                kill(pid, SIGTERM)
            }
        }
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testRepositoryListsAndDeletesThroughAVDManager() throws {
        let repository = AVDRepository(tools: tools)
        let avds = try repository.listAVDs()

        XCTAssertEqual(avds.count, 1)
        XCTAssertEqual(avds[0].name, avdName)
        XCTAssertEqual(avds[0].path, avdDirectory.path)
        XCTAssertEqual(avds[0].apiLevel, 30)
        XCTAssertEqual(avds[0].abi, "arm64-v8a")

        try repository.deleteAVD(named: avdName)
        XCTAssertTrue(recordedCommands().contains("-s delete avd -n \(avdName!)"))
    }

    func testStartAndStopFallbackByProcess() throws {
        let controller = makeController()
        try controller.start(avdName: avdName, mode: .normal)

        XCTAssertNotNil(waitForPID(controller), "启动后未找到 mock emulator 进程")
        XCTAssertTrue(waitForRecord(containing: "-avd \(avdName!)"))

        try controller.stop(serial: nil, avdName: avdName)
        XCTAssertNil(controller.findEmulatorPID(avdName: avdName))
    }

    func testWipeRemovesDataImagesAndKeepsSnapshots() throws {
        let controller = makeController()
        try controller.start(avdName: avdName, mode: .normal)
        XCTAssertNotNil(waitForPID(controller))
        XCTAssertTrue(waitForRecord(containing: "-avd \(avdName!)"))

        try controller.wipeData(
            avdName: avdName,
            avdPath: avdDirectory.path,
            serial: nil
        )
        XCTAssertNotNil(waitForPID(controller))
        XCTAssertTrue(waitForStartCount(2))

        let files = FileManager.default
        for name in EmulatorController.wipeFileNames {
            XCTAssertFalse(
                files.fileExists(atPath: avdDirectory.appendingPathComponent(name).path),
                "\(name) 应被删除"
            )
        }
        XCTAssertTrue(
            files.fileExists(atPath: avdDirectory.appendingPathComponent("userdata.img").path),
            "userdata.img 初始模板应保留"
        )
        XCTAssertFalse(
            files.fileExists(atPath: avdDirectory.appendingPathComponent("snapshots").path),
            "旧 snapshots 应被改名归档"
        )
        let archived = try files.contentsOfDirectory(atPath: avdDirectory.path)
            .filter { $0.hasPrefix("snapshots.pre-wipe-") }
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(
            files.fileExists(
                atPath: avdDirectory.appendingPathComponent(archived[0])
                    .appendingPathComponent("default_boot/snapshot.pb").path
            ),
            "归档目录中应保留旧快照文件"
        )

        let starts = recordedCommands().components(separatedBy: .newlines)
            .filter { $0.hasPrefix("-avd \(avdName!)") }
        XCTAssertGreaterThanOrEqual(starts.count, 2)
        XCTAssertTrue(starts.last?.contains("-no-snapshot-load") == true)

        try controller.stop(serial: nil, avdName: avdName)
    }

    func testRebootAndRunningMonitorUseADB() throws {
        let controller = makeController()
        try controller.reboot(serial: "emulator-5554", avdName: avdName)
        XCTAssertTrue(recordedCommands().contains("-s emulator-5554 reboot"))

        let running = try DeviceMonitor(tools: tools).runningDevices()
        XCTAssertEqual(running.count, 2)
        let emulator = running.first { $0.serial == "emulator-5554" }
        XCTAssertNotNil(emulator)
        XCTAssertEqual(emulator?.avdName, avdName)
        XCTAssertTrue(emulator?.isBooted == true)
        XCTAssertFalse(emulator?.isRealDevice ?? true)
    }

    func testRebootRejectsStaleSerial() throws {
        let controller = makeController()
        XCTAssertThrowsError(
            try controller.reboot(serial: "emulator-5554", avdName: "AnotherAVD")
        ) { error in
            guard case EmulatorError.serialMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRealDeviceDetectionAndProps() throws {
        let running = try DeviceMonitor(tools: tools).runningDevices()
        let real = running.first { $0.isRealDevice }
        XCTAssertNotNil(real, "mock adb 应报告一台真机")
        XCTAssertEqual(real?.serial, "MOCKSERIAL01")
        XCTAssertTrue(real?.isBooted == true)

        let monitor = DeviceMonitor(tools: tools)
        let props = try monitor.deviceProps(serial: "MOCKSERIAL01")
        XCTAssertEqual(props.model, "Mock Phone 15")
        XCTAssertEqual(props.androidVersion, "16")
        XCTAssertEqual(props.apiLevel, 36)
    }

    func testProvisioningAndSnapshotCommandsAreWired() throws {
        let provisioning = AVDProvisioningService(tools: tools)
        XCTAssertEqual(
            try provisioning.deviceProfiles(),
            ["Nexus 5X", "medium_phone", "pixel_7a"]
        )

        let newName = "MockNew\(UUID().uuidString.prefix(6))"
        let renamed = "MockRenamed\(UUID().uuidString.prefix(6))"
        try provisioning.create(
            name: newName,
            imageID: "system-images;android-34;google_apis_playstore;arm64-v8a",
            device: "pixel_7a"
        )
        XCTAssertTrue(
            recordedCommands().contains("create avd -n \(newName) -k system-images;android-34;google_apis_playstore;arm64-v8a -d pixel_7a")
        )

        try provisioning.rename(oldName: newName, newName: renamed)
        XCTAssertTrue(recordedCommands().contains("move avd -n \(newName) -r \(renamed)"))

        try provisioning.move(name: renamed, toPath: "/tmp/Moved.avd")
        XCTAssertTrue(recordedCommands().contains("move avd -n \(renamed) -p /tmp/Moved.avd"))

        let snapshots = SnapshotService(tools: tools)
        XCTAssertEqual(snapshots.list(avdPath: avdDirectory.path), ["named_snapshot"])
        try snapshots.save(serial: "emulator-5554", avdName: avdName, name: "snap1")
        try snapshots.load(serial: "emulator-5554", avdName: avdName, name: "snap1")
        try snapshots.delete(
            serial: "emulator-5554",
            avdName: avdName,
            avdPath: avdDirectory.path,
            name: "snap1"
        )
        let record = recordedCommands()
        XCTAssertTrue(record.contains("-s emulator-5554 emu avd snapshot save snap1"))
        XCTAssertTrue(record.contains("-s emulator-5554 emu avd snapshot load snap1"))
        XCTAssertTrue(record.contains("-s emulator-5554 emu avd snapshot delete snap1"))

        try makeController().sendKey(serial: "emulator-5554", keycode: 4)
        XCTAssertTrue(recordedCommands().contains("-s emulator-5554 shell input keyevent 4"))

        let resolution = try makeController().deviceResolution(serial: "emulator-5554")
        XCTAssertEqual(resolution.width, 1080)
        XCTAssertEqual(resolution.height, 2400)

        try makeController().sendTap(serial: "emulator-5554", x: 100, y: 200)
        XCTAssertTrue(recordedCommands().contains("-s emulator-5554 shell input tap 100 200"))

        try makeController().sendSwipe(
            serial: "emulator-5554",
            x1: 10, y1: 20, x2: 300, y2: 400,
            durationMs: 300
        )
        XCTAssertTrue(
            recordedCommands().contains("-s emulator-5554 shell input swipe 10 20 300 400 300")
        )
    }

    func testEarlyExitIsReported() throws {
        let crashURL = root.appendingPathComponent("crash-emulator")
        try writeScript(
            at: crashURL,
            contents: """
            #!/bin/sh
            echo "mock failure" >&2
            exit 7
            """
        )
        let crashTools = ToolPaths(
            avdmanager: tools.avdmanager,
            emulator: crashURL,
            adb: tools.adb,
            sdkRoot: tools.sdkRoot,
            javaHome: tools.javaHome
        )
        let controller = EmulatorController(
            tools: crashTools,
            logDirectory: root.appendingPathComponent("logs")
        )

        let expectation = expectation(description: "早期退出回调")
        let captured = CapturedExit()
        controller.onExit = { _, status, log, intentional in
            captured.set(status: status, intentional: intentional, log: log)
            expectation.fulfill()
        }
        try controller.start(avdName: avdName, mode: .normal)
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(captured.status, 7)
        XCTAssertFalse(captured.intentional)
        XCTAssertTrue(captured.log.contains("mock failure"))
    }

    func testIntentionalStopIsMarked() throws {
        let controller = makeController()
        let expectation = expectation(description: "主动停止回调")
        let captured = CapturedExit()
        controller.onExit = { _, status, _, intentional in
            captured.set(status: status, intentional: intentional, log: "")
            expectation.fulfill()
        }

        try controller.start(avdName: avdName, mode: .normal)
        XCTAssertNotNil(waitForPID(controller))
        try controller.stop(serial: nil, avdName: avdName)
        wait(for: [expectation], timeout: 5)

        XCTAssertTrue(captured.intentional)
    }

    func testSnapshotKOIsRejected() throws {
        let koAdb = root.appendingPathComponent("ko-adb")
        try writeScript(
            at: koAdb,
            contents: """
            #!/bin/sh
            case "$1" in
              -s)
                if [ "$3" = "emu" ] && [ "$4" = "avd" ] && [ "$5" = "name" ]; then
                  echo "\(avdName!)"
                  echo "OK"
                else
                  echo "KO: no snapshot"
                fi
                ;;
            esac
            exit 0
            """
        )
        let koTools = ToolPaths(
            avdmanager: tools.avdmanager,
            emulator: tools.emulator,
            adb: koAdb,
            sdkRoot: tools.sdkRoot,
            javaHome: tools.javaHome
        )
        let service = SnapshotService(tools: koTools)
        XCTAssertThrowsError(
            try service.save(serial: "emulator-5554", avdName: avdName, name: "snap1")
        ) { error in
            guard case SnapshotError.consoleFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - 辅助

    private func makeController() -> EmulatorController {
        EmulatorController(tools: tools, logDirectory: root.appendingPathComponent("logs"))
    }

    private func waitForPID(_ controller: EmulatorController, timeout: TimeInterval = 5) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = controller.findEmulatorPID(avdName: avdName) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func recordedCommands() -> String {
        (try? String(contentsOf: recordFile, encoding: .utf8)) ?? ""
    }

    private func waitForRecord(containing text: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recordedCommands().contains(text) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func waitForStartCount(_ minimum: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recordedCommands()
                .components(separatedBy: .newlines)
                .filter { $0.hasPrefix("-avd \(avdName!)") }
                .count
            if count >= minimum {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func writeScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func avdmanagerScript() -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        if [ "$1" = "list" ] && [ "$2" = "device" ]; then
          echo "medium_phone"
          echo "Nexus 5X"
          echo "pixel_7a"
          exit 0
        fi
        if [ "$1" = "list" ]; then
          cat <<'EOF'
        Available Android Virtual Devices:
            Name: \(avdName!)
          Device: pixel_5 (Google)
            Path: \(avdDirectory.path)
          Target: Google APIs (Google Inc.)
                  Based on: Android 11.0 ("R") Tag/ABI: google_apis/arm64-v8a
          Sdcard: 4G
        ---------
        EOF
        fi
        exit 0
        """
    }

    private func sleepingEmulatorScript() -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        trap 'exit 0' TERM INT
        while true; do sleep 0.2; done
        """
    }

    private func adbScript() -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        case "$1" in
          devices)
            echo "List of devices attached"
            echo "emulator-5554          device"
            echo "MOCKSERIAL01           device"
            ;;
          -s)
            case "$3" in
              emu) echo "\(avdName!)"; echo "OK" ;;
              shell)
                if [ "$4" = "wm" ]; then
                  echo "Physical size: 1080x2400"
                else
                  case "$5" in
                    sys.boot_completed) echo "1" ;;
                    ro.product.model) echo "Mock Phone 15" ;;
                    ro.build.version.release) echo "16" ;;
                    ro.build.version.sdk) echo "36" ;;
                    *) echo "1" ;;
                  esac
                fi ;;
            esac
            ;;
        esac
        exit 0
        """
    }
}

private final class CapturedExit {
    private let lock = NSLock()
    private var _status: Int32 = -1
    private var _intentional = false
    private var _log = ""

    func set(status: Int32, intentional: Bool, log: String) {
        lock.lock()
        _status = status
        _intentional = intentional
        _log = log
        lock.unlock()
    }

    var status: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    var intentional: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _intentional
    }

    var log: String {
        lock.lock()
        defer { lock.unlock() }
        return _log
    }
}
