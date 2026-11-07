import XCTest
@testable import AVDCore

/// 依赖本机 Xcode 与 baguette 的 iOS 模拟器真机流冒烟测试，默认跳过。
/// 运行：AVD_IOS_INTEGRATION=1 swift test --filter IOSRealDeviceTests
///
/// 需要 baguette 二进制：优先取环境变量 `AVD_BAGUETTE` 指定的路径，
/// 否则用仓库内 `Vendor/baguette/Baguette`（获取步骤见 README）。
/// 流程对应设计 §5.3：临时设备 boot → AVCC 流出帧 → 截图 → 按键落地 → 清理。
final class IOSRealDeviceTests: XCTestCase {
    private var simctl: SimctlService!
    private var baguette: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["AVD_IOS_INTEGRATION"] == "1" else {
            throw XCTSkip("设置 AVD_IOS_INTEGRATION=1 后运行")
        }
        guard let simctlURL = SimctlService.locateSystemSimctl() else {
            throw XCTSkip("未找到 simctl（需要完整 Xcode）")
        }
        simctl = SimctlService(simctl: simctlURL)
        baguette = try Self.locateBaguette()
    }

    /// baguette 定位：AVD_BAGUETTE 环境变量优先，否则从测试文件位置回溯仓库根的 Vendor。
    private static func locateBaguette() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AVD_BAGUETTE"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw XCTSkip("AVD_BAGUETTE 指向的二进制不可执行：\(override)")
            }
            return url
        }
        // <repo>/Tests/AVDCoreTests/IOSRealDeviceTests.swift → <repo>/Vendor/baguette/Baguette
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Vendor/baguette/Baguette")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("缺少 baguette 二进制（\(url.path)），按 README 放置后重试")
        }
        return url
    }

    /// 真机流全链路：创建临时设备 → boot → baguette AVCC 流出帧 → 截图 →
    /// Home 键落地（影子时走 heal 重试）→ 清理。断言失败会留下诊断信息。
    func testBootStreamInputLifecycle() throws {
        let runtimes = try simctl.listRuntimes()
            .filter { $0.isIOS && $0.isAvailable }
            .sorted { $0.version > $1.version }
        guard let runtime = runtimes.first else {
            throw XCTSkip("本机没有可用的 iOS runtime")
        }
        let deviceType = runtime.supportedDeviceTypes.first { $0.productFamily == "iPhone" }
            ?? runtime.supportedDeviceTypes.first
        guard let deviceType else {
            throw XCTSkip("runtime \(runtime.version) 没有可选机型")
        }

        let name = "AVDMenuBar-IOS-IT"
        let udid = try simctl.create(name: name, deviceType: deviceType.identifier, runtime: runtime.identifier)
        defer {
            try? simctl.shutdown(udid: udid)
            try? simctl.delete(udid: udid)
        }
        print("[IT] 临时设备 \(name) \(udid) @ iOS \(runtime.version) / \(deviceType.name)")

        try simctl.boot(udid: udid)
        XCTAssertTrue(waitUntil(120) { (try? self.simctl.listDevices())?.first { $0.udid == udid }?.state == "Booted" },
                      "120 秒内未进入 Booted")
        pump(5) // SpringBoard 收尾动画
        freezeStatusBarClock(udid: udid) // 截图 diff 不被时钟翻转干扰

        // —— AVCC 流：首帧 + 连续帧 ——
        let controller = BaguetteController()
        defer { controller.stop() }
        var frameCount = 0
        var lastFrameSize = CGSize.zero
        controller.onFrame = { image, size in
            frameCount += 1
            lastFrameSize = size
            _ = image
        }
        controller.start(udid: udid, baguette: baguette)
        XCTAssertTrue(waitUntil(60) { controller.frame != nil }, "60 秒内未收到首帧")
        let framesAtStart = frameCount
        pump(3)
        XCTAssertGreaterThanOrEqual(frameCount - framesAtStart, 3, "3 秒内帧数未增长，流可能停滞")
        XCTAssertGreaterThanOrEqual(lastFrameSize.width, 300, "帧尺寸异常：\(lastFrameSize)")
        print("[IT] 流正常：首帧后 3s 增 \(frameCount - framesAtStart) 帧，尺寸 \(lastFrameSize)")

        // —— 截图路径 ——
        let springBoard = try simctl.screenshot(udid: udid)
        XCTAssertEqual([UInt8](springBoard.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "截图不是 PNG")

        // —— Home 键落地：启动设置 → 按键 → 截图变化；影子时 heal 后重试一次 ——
        try simctl.launchApp(udid: udid, bundleID: "com.apple.Preferences")
        pump(2)
        let settingsShot = try simctl.screenshot(udid: udid)
        XCTAssertNotEqual(Self.hash(settingsShot), Self.hash(springBoard), "设置启动后截图未变化")

        let session = BaguetteInputSession()
        defer { session.stop() }
        session.start(udid: udid, baguette: baguette)
        pump(2) // input 启动 + HID 预热
        try session.send(.tap(x: 201, y: 437, width: 402, height: 874, duration: 0.05))
        pump(1)

        func homeReturnsToSpringBoard() -> Bool {
            try? session.send(.key(.home))
            return waitUntil(8) {
                guard let shot = try? self.simctl.screenshot(udid: udid) else { return false }
                return Self.hash(shot) != Self.hash(settingsShot)
            }
        }
        var landed = homeReturnsToSpringBoard()
        if !landed {
            // Device Hub 抢占输入面（dtuhidd）时按键必失效；heal 重启 backboardd 后重试。
            print("[IT] Home 未落地，尝试 baguette heal 后重试")
            let outcome = try BaguetteController.heal(udid: udid, baguette: baguette)
            print("[IT] heal 结果：\(outcome)")
            pump(10) // backboardd/SpringBoard 重启
            try simctl.launchApp(udid: udid, bundleID: "com.apple.Preferences")
            pump(2)
            landed = homeReturnsToSpringBoard()
        }
        XCTAssertTrue(landed, "Home 键未引起界面变化（输入面未落地）")
        print("[IT] 输入路径落地正常")
    }

    // MARK: - 等待与哈希辅助

    /// 泵主线程 RunLoop 的等待： Baguette 的回调都经 DispatchQueue.main 投递，
    /// 纯 Thread.sleep 会让它们饿死，这里统一用 RunLoop 轮询。
    @discardableResult
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            pump(0.2)
        }
        return condition()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 冻结状态栏时钟（9:41），避免截图 diff 被分钟翻转误触发；失败不阻塞测试。
    private func freezeStatusBarClock(udid: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", udid, "status_bar", "override", "--time", "9:41"]
        try? process.run()
        process.waitUntilExit()
    }

    /// FNV-1a 64：测试内判断两张截图是否同一画面，无需引入 CryptoKit。
    private static func hash(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash
    }
}
