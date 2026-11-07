import XCTest
@testable import SimDeckCore

/// 按设计文档 §5.2 的"假可执行 + 参数记录"模式验证 simctl 封装：
/// 列表、启停、删除、擦除前置 shutdown、创建/重命名、截图与输入影子检测。
/// 默认跳过；运行：AVD_MOCK_E2E=1 swift test --filter SimctlMockE2ETests
final class SimctlMockE2ETests: XCTestCase {
    private var root: URL!
    private var recordFile: URL!
    private var shadowFlag: URL!
    private var service: SimctlService!
    private var monitor: SimulatorMonitor!

    private static let bootedUDID = "11111111-2222-3333-4444-555555555555"
    private static let bootingUDID = "22222222-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["AVD_MOCK_E2E"] == "1" else {
            throw XCTSkip("设置 AVD_MOCK_E2E=1 后运行")
        }

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimDeckSimctlMock-\(UUID().uuidString)")
        recordFile = root.appendingPathComponent("record.txt")
        shadowFlag = root.appendingPathComponent("dtuhidd-shadow")

        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
              {
                "udid" : "\(Self.bootedUDID)",
                "name" : "Mock iPhone",
                "state" : "Booted",
                "isAvailable" : true,
                "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "dataPath" : "\(root.path)/data"
              },
              {
                "udid" : "\(Self.bootingUDID)",
                "name" : "Mock iPad",
                "state" : "Booting",
                "isAvailable" : true,
                "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"
              }
            ]
          }
        }
        """.write(to: root.appendingPathComponent("devices.json"), atomically: true, encoding: .utf8)
        try """
        {
          "devicetypes" : [
            { "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPad-Pro", "name" : "iPad Pro" },
            { "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name" : "iPhone 17 Pro" }
          ]
        }
        """.write(to: root.appendingPathComponent("devicetypes.json"), atomically: true, encoding: .utf8)
        try """
        {
          "runtimes" : [
            {
              "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
              "version" : "27.0",
              "buildversion" : "24A434",
              "isAvailable" : true
            },
            {
              "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-6",
              "version" : "18.6",
              "buildversion" : "22G86",
              "isAvailable" : false
            },
            {
              "identifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
              "version" : "11.0",
              "isAvailable" : true
            }
          ]
        }
        """.write(to: root.appendingPathComponent("runtimes.json"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>com.example.demo</key>
          <dict>
            <key>CFBundleIdentifier</key>
            <string>com.example.demo</string>
            <key>CFBundleDisplayName</key>
            <string>Demo</string>
            <key>CFBundleShortVersionString</key>
            <string>1.2.3</string>
          </dict>
          <key>com.example.noname</key>
          <dict>
            <key>CFBundleIdentifier</key>
            <string>com.example.noname</string>
          </dict>
          <key>com.apple.Preferences</key>
          <dict>
            <key>CFBundleIdentifier</key>
            <string>com.apple.Preferences</string>
            <key>CFBundleName</key>
            <string>Settings</string>
          </dict>
        </dict>
        </plist>
        """.write(to: root.appendingPathComponent("listapps.plist"), atomically: true, encoding: .utf8)

        try writeScript(at: root.appendingPathComponent("simctl"), contents: simctlScript())

        service = SimctlService(simctl: root.appendingPathComponent("simctl"))
        monitor = SimulatorMonitor(simctl: service)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - 列表

    func testMonitorListsDevicesThroughFakeSimctl() throws {
        let devices = try monitor.devices()

        XCTAssertEqual(devices.count, 2)
        let iphone = try XCTUnwrap(devices.first { $0.udid == Self.bootedUDID })
        let ipad = try XCTUnwrap(devices.first { $0.udid == Self.bootingUDID })
        XCTAssertEqual(iphone.state, "Booted")
        XCTAssertTrue(iphone.isBooted)
        XCTAssertEqual(iphone.runtimeVersion, "27.0")
        XCTAssertEqual(iphone.deviceTypeName, "iPhone 17 Pro", "类型名应通过 list -j devicetypes 映射")
        XCTAssertEqual(ipad.state, "Booting", "未知/中间状态应原样保留")
        XCTAssertTrue(recordedCommands().contains("list -j devices"))
        XCTAssertTrue(recordedCommands().contains("list -j devicetypes"))
    }

    // MARK: - 生命周期

    func testBootShutdownRebootRecordArguments() throws {
        try service.boot(udid: Self.bootedUDID)
        try service.shutdown(udid: Self.bootedUDID)
        try service.reboot(udid: Self.bootedUDID)

        let record = recordedCommands()
        XCTAssertTrue(record.contains("boot \(Self.bootedUDID)"))
        XCTAssertTrue(record.contains("shutdown \(Self.bootedUDID)"))
        XCTAssertTrue(record.contains("reboot \(Self.bootedUDID)"))
    }

    func testDeleteRecordsCommand() throws {
        try service.delete(udid: Self.bootingUDID)
        XCTAssertTrue(recordedCommands().contains("delete \(Self.bootingUDID)"))
    }

    func testEraseShutsDownBootedDeviceFirst() throws {
        try service.erase(udid: Self.bootedUDID, isBooted: true)

        let lines = recordedCommands().components(separatedBy: .newlines)
        let shutdownIndex = try XCTUnwrap(lines.firstIndex(of: "shutdown \(Self.bootedUDID)"))
        let eraseIndex = try XCTUnwrap(lines.firstIndex(of: "erase \(Self.bootedUDID)"))
        XCTAssertLessThan(shutdownIndex, eraseIndex, "erase 前必须先 shutdown")
    }

    func testEraseSkipsShutdownWhenNotBooted() throws {
        try service.erase(udid: Self.bootingUDID, isBooted: false)

        let record = recordedCommands()
        XCTAssertFalse(record.contains("shutdown \(Self.bootingUDID)"))
        XCTAssertTrue(record.contains("erase \(Self.bootingUDID)"))
    }

    func testCreateRecordsArgumentsAndReturnsUDID() throws {
        let udid = try service.create(
            name: "Mock Sim",
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        )
        XCTAssertEqual(udid, "NEW-UDID-0001")
        XCTAssertTrue(
            recordedCommands().contains(
                "create Mock Sim com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0"
            )
        )
    }

    func testRenameRecordsArguments() throws {
        try service.rename(udid: Self.bootedUDID, to: "Renamed iPhone")
        XCTAssertTrue(recordedCommands().contains("rename \(Self.bootedUDID) Renamed iPhone"))
    }

    // MARK: - 创建向导候选

    /// 设计 §6 Phase 4 AC——向导只能选可用组合：`list -j runtimes` 含未安装条目，
    /// iosRuntimes() 必须剔除 unavailable 与非 iOS runtime。
    func testIOSRuntimesExcludeUnavailableAndNonIOS() throws {
        let runtimes = try monitor.iosRuntimes()

        XCTAssertEqual(runtimes.map(\.version), ["27.0"], "只保留可用的 iOS runtime")
        XCTAssertTrue(runtimes.allSatisfy(\.isAvailable))
        XCTAssertTrue(recordedCommands().contains("list -j runtimes"))
    }

    // MARK: - App 管理

    func testInstallUninstallTerminateRecordArguments() throws {
        try service.installApp(udid: Self.bootedUDID, appBundlePath: "/tmp/Demo.app")
        try service.uninstallApp(udid: Self.bootedUDID, bundleID: "com.example.demo")
        try service.terminateApp(udid: Self.bootedUDID, bundleID: "com.example.demo")

        let record = recordedCommands()
        XCTAssertTrue(record.contains("install \(Self.bootedUDID) /tmp/Demo.app"))
        XCTAssertTrue(record.contains("uninstall \(Self.bootedUDID) com.example.demo"))
        XCTAssertTrue(record.contains("terminate \(Self.bootedUDID) com.example.demo"))
    }

    func testLaunchAppReturnsPidFromStdout() throws {
        let pid = try service.launchApp(udid: Self.bootedUDID, bundleID: "com.example.demo")
        XCTAssertEqual(pid, "12345", "simctl launch 的 stdout 是进程 pid")
        XCTAssertTrue(recordedCommands().contains("launch \(Self.bootedUDID) com.example.demo"))
    }

    func testOpenURLRecordsArgumentsAndReturnsStdout() throws {
        let output = try service.openURL(udid: Self.bootedUDID, url: "myapp://demo")
        XCTAssertEqual(output, "")
        XCTAssertTrue(recordedCommands().contains("openurl \(Self.bootedUDID) myapp://demo"))
    }

    func testListAppsParsesPlistOutput() throws {
        let apps = try service.listApps(udid: Self.bootedUDID)

        XCTAssertEqual(apps.map(\.bundleID), [
            "com.apple.Preferences",
            "com.example.demo",
            "com.example.noname"
        ], "按 bundle id 升序")

        let demo = try XCTUnwrap(apps.first { $0.bundleID == "com.example.demo" })
        XCTAssertEqual(demo.name, "Demo")
        XCTAssertEqual(demo.version, "1.2.3")
        let settings = try XCTUnwrap(apps.first { $0.bundleID == "com.apple.Preferences" })
        XCTAssertEqual(settings.name, "Settings", "显示名优先取 CFBundleDisplayName")
        let noName = try XCTUnwrap(apps.first { $0.bundleID == "com.example.noname" })
        XCTAssertEqual(noName.name, "com.example.noname", "缺名称字段回退 bundle id")
        XCTAssertNil(noName.version)
    }

    func testListAppsRejectsBrokenOutput() {
        XCTAssertThrowsError(try service.listApps(udid: Self.bootingUDID))
    }

    // MARK: - 截图与影子检测

    func testScreenshotWritesToTempFileAndReadsBack() throws {
        let data = try service.screenshot(udid: Self.bootedUDID)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PNG-BYTES")
        XCTAssertTrue(recordedCommands().contains("io \(Self.bootedUDID) screenshot "))
    }

    func testScreenshotFailsWhenFakeWritesNothing() throws {
        XCTAssertThrowsError(try service.screenshot(udid: Self.bootingUDID))
    }

    func testIsInputShadowedFollowsNotifyutilOutput() throws {
        XCTAssertFalse(service.isInputShadowed(udid: Self.bootedUDID))
        XCTAssertTrue(
            recordedCommands().contains("spawn \(Self.bootedUDID) notifyutil -g com.apple.coredevice.dtuhidd.active")
        )

        try "1".write(to: shadowFlag, atomically: true, encoding: .utf8)
        XCTAssertTrue(service.isInputShadowed(udid: Self.bootedUDID))
    }

    func testLocateSystemSimctlPrefersDeveloperDir() throws {
        let developerDir = root.appendingPathComponent("MockXcode.app/Contents/Developer")
        try FileManager.default.createDirectory(
            at: developerDir.appendingPathComponent("usr/bin"),
            withIntermediateDirectories: true
        )
        try writeScript(at: developerDir.appendingPathComponent("usr/bin/simctl"), contents: "#!/bin/sh\n")

        let located = SimctlService.locateSystemSimctl(environment: ["DEVELOPER_DIR": developerDir.path])
        XCTAssertEqual(located, developerDir.appendingPathComponent("usr/bin/simctl"))
    }

    // MARK: - 辅助

    private func recordedCommands() -> String {
        (try? String(contentsOf: recordFile, encoding: .utf8)) ?? ""
    }

    private func writeScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func simctlScript() -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        case "$1" in
          list)
            if [ "$3" = "devices" ]; then
              cat "\(root.appendingPathComponent("devices.json").path)"
            elif [ "$3" = "devicetypes" ]; then
              cat "\(root.appendingPathComponent("devicetypes.json").path)"
            elif [ "$3" = "runtimes" ]; then
              cat "\(root.appendingPathComponent("runtimes.json").path)"
            fi
            ;;
          create)
            echo "NEW-UDID-0001"
            ;;
          listapps)
            if [ "$2" = "\(Self.bootedUDID)" ]; then
              cat "\(root.appendingPathComponent("listapps.plist").path)"
            else
              echo "not a plist"
            fi
            ;;
          launch)
            echo "12345"
            ;;
          io)
            if [ "$3" = "screenshot" ] && [ "$2" = "\(Self.bootedUDID)" ]; then
              printf 'PNG-BYTES' > "$4"
            fi
            ;;
          spawn)
            if [ -f "\(shadowFlag.path)" ]; then
              echo "1"
            else
              echo "0"
            fi
            ;;
        esac
        exit 0
        """
    }
}
