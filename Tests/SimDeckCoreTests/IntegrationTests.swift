import XCTest
@testable import SimDeckCore

/// 依赖本机 Android SDK 的冒烟测试，默认跳过。
/// 运行：AVD_INTEGRATION=1 swift test --filter IntegrationTests
final class IntegrationTests: XCTestCase {
    func testRealSDKListingAndRunningState() throws {
        guard ProcessInfo.processInfo.environment["AVD_INTEGRATION"] == "1" else {
            throw XCTSkip("设置 AVD_INTEGRATION=1 后运行")
        }

        let tools = try ToolLocator.resolve()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tools.avdmanager.path))
        XCTAssertNotNil(tools.emulator)
        XCTAssertNotNil(tools.adb)
        XCTAssertNotNil(tools.javaHome, "avdmanager 需要 Java")
        print("JAVA_HOME: \(tools.javaHome?.path ?? "nil")")

        // 若本机同时装有 JDK 8，确认会选择 17+ 的 JDK。
        let jdk8 = "/Library/Java/JavaVirtualMachines/zulu-8.jdk/Contents/Home"
        if FileManager.default.isExecutableFile(atPath: jdk8 + "/bin/java") {
            let withJdk8 = try ToolLocator.resolve(environment: ["JAVA_HOME": jdk8])
            XCTAssertNotEqual(withJdk8.javaHome?.path, jdk8)
            print("JAVA_HOME(覆盖为 JDK 8 时实际选择): \(withJdk8.javaHome?.path ?? "nil")")
        }

        let avds = try AVDRepository(tools: tools).listAVDs()
        XCTAssertFalse(avds.isEmpty)
        for avd in avds {
            XCTAssertFalse(avd.name.isEmpty)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: avd.path),
                "AVD 目录不存在：\(avd.path)"
            )
            XCTAssertNotNil(avd.apiLevel, "\(avd.name) 未解析出 API level")
        }

        let running = try DeviceMonitor(tools: tools).runningDevices()
        for device in running {
            XCTAssertFalse(device.serial.isEmpty)
        }

        if let device = running.first, let name = device.avdName {
            let controller = EmulatorController(
                tools: tools,
                logDirectory: FileManager.default.temporaryDirectory
            )
            XCTAssertNotNil(
                controller.findEmulatorPID(avdName: name),
                "未按 -avd \(name) 匹配到模拟器进程"
            )
        }

        print("解析到 AVD：\(avds.map { "\($0.name) [\($0.summary)]" })")
        print("运行中：\(running.map { "\($0.displayName)/\($0.serial)/booted=\($0.isBooted)" })")
    }

    /// 验证 ADB H264 实时流能解出帧（要求本机有已开机的模拟器）。
    /// 这会在设备上短暂启动 screenrecord 会话，测试结束后自动停止。
    func testADBH264StreamProducesFrames() throws {
        let tools = try ToolLocator.resolve()
        guard let adb = tools.adb else { throw XCTSkip("没有 adb") }
        let booted = try DeviceMonitor(tools: tools).runningDevices().filter(\.isBooted)
        guard let device = booted.first else { throw XCTSkip("没有已开机的模拟器") }
        if Self.deviceDisplayIsOff(serial: device.serial) {
            throw XCTSkip("设备屏幕已熄灭（\(device.serial)），screenrecord 无画面")
        }

        let streamer = ADBH264Streamer()
        let gotFrames = expectation(description: "收到至少 5 帧")
        gotFrames.assertForOverFulfill = false
        var frames = 0
        streamer.onFrame = { _, _ in
            frames += 1
            if frames >= 5 {
                gotFrames.fulfill()
            }
        }
        streamer.start(
            serial: device.serial,
            adb: adb,
            environment: ToolEnvironment.make(tools: tools)
        )
        wait(for: [gotFrames], timeout: 25)
        streamer.stop()
        // 设备端 screenrecord 编码器是单实例，stop 后需要等设备释放（华为可达 10s+）
        Thread.sleep(forTimeInterval: 10)

        XCTAssertGreaterThanOrEqual(frames, 5)
        print("H264 流收到帧数：\(frames)（设备：\(device.serial)）")
    }

    /// 华为等设备熄屏后 screenrecord 报 UNASSIGNED_LAYER_STACK，无法出帧。
    private static func deviceDisplayIsOff(serial: String) -> Bool {
        guard let adb = try? ToolLocator.resolve().adb else { return false }
        guard let result = try? CommandRunner.run(
            adb,
            ["-s", serial, "shell", "dumpsys", "display"],
            environment: ToolEnvironment.make(tools: try! ToolLocator.resolve()),
            timeout: 15
        ), result.status == 0 else {
            return false
        }
        return result.stdout.contains("mState=OFF")
    }

    /// 验证 ADB H264 流的帧宽高比与设备分辨率一致（无标题栏，触摸映射 1:1）。
    func testADBH264StreamFrameSizeMatchesDevice() throws {
        let tools = try ToolLocator.resolve()
        guard let adb = tools.adb else { throw XCTSkip("没有 adb") }
        let booted = try DeviceMonitor(tools: tools).runningDevices().filter(\.isBooted)
        guard let device = booted.first else { throw XCTSkip("没有已开机的模拟器") }
        if Self.deviceDisplayIsOff(serial: device.serial) {
            throw XCTSkip("设备屏幕已熄灭（\(device.serial)），screenrecord 无画面")
        }

        let resolution = try EmulatorController(
            tools: tools,
            logDirectory: FileManager.default.temporaryDirectory
        ).deviceResolution(serial: device.serial)

        let streamer = ADBH264Streamer()
        let gotFrame = expectation(description: "收到首帧")
        gotFrame.assertForOverFulfill = false
        var firstSize: CGSize?
        streamer.onFrame = { _, size in
            if firstSize == nil {
                firstSize = size
                gotFrame.fulfill()
            }
        }
        streamer.start(
            serial: device.serial,
            adb: adb,
            environment: ToolEnvironment.make(tools: tools)
        )
        wait(for: [gotFrame], timeout: 25)
        streamer.stop()
        Thread.sleep(forTimeInterval: 10)

        guard let size = firstSize else {
            return XCTFail("没有收到帧")
        }
        let frameAspect = size.width / size.height
        let deviceAspect = resolution.width / resolution.height
        XCTAssertEqual(frameAspect, deviceAspect, accuracy: 0.05)
        print("H264 帧尺寸：\(size)，设备分辨率：\(resolution)")
    }
}
