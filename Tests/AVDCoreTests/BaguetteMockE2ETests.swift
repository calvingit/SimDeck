import XCTest
@testable import AVDCore

/// 按设计文档 §5.2 的"假可执行 + 参数记录"模式验证 baguette stream 子进程管理：
/// 默认参数、AVCC 回放解码、SIGINT 干净退出、异常退出回调与二进制定位。
/// 默认跳过；运行：AVD_MOCK_E2E=1 swift test --filter BaguetteMockE2ETests
final class BaguetteMockE2ETests: XCTestCase {
    private var root: URL!
    private var recordFile: URL!
    private var cannedStream: URL!
    private var baguetteScript: URL!

    private static let udid = "AAAA-BBBB-CCCC-DDDD"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["AVD_MOCK_E2E"] == "1" else {
            throw XCTSkip("设置 AVD_MOCK_E2E=1 后运行")
        }

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVDMenuBarBaguetteMock-\(UUID().uuidString)")
        recordFile = root.appendingPathComponent("record.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 用真实 VideoToolbox 编码产出可解码的 canned AVCC 字节
        let stream = try TestH264Encoder.encode(width: 64, height: 48)
        var canned = TestH264Encoder.makeFrame(tag: 0x01, payload: stream.avcC)
        canned += TestH264Encoder.makeFrame(tag: 0x02, payload: stream.idr)
        canned += TestH264Encoder.makeFrame(tag: 0x03, payload: stream.delta)
        cannedStream = root.appendingPathComponent("canned.avcc")
        try canned.write(to: cannedStream)

        baguetteScript = root.appendingPathComponent("baguette")
        try writeScript(at: baguetteScript, contents: streamScript())
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - stream 回放与停止

    func testStreamReplaysCannedAVCCWithDefaultArgumentsAndStopsOnSIGINT() throws {
        let controller = BaguetteController()
        let firstFrame = expectation(description: "回放流解码出首帧")
        var frameSize: CGSize?
        controller.onFrame = { image, size in
            guard frameSize == nil else { return }
            XCTAssertEqual(Int(image.width), 64)
            frameSize = size
            firstFrame.fulfill()
        }

        controller.start(udid: Self.udid, baguette: baguetteScript)
        wait(for: [firstFrame], timeout: 10)
        XCTAssertEqual(frameSize?.width, 64)
        XCTAssertEqual(frameSize?.height, 48)
        XCTAssertTrue(controller.isRunning)
        // state 转换 .starting → .active 在 onFrame 之后异步派发，轮询等待
        let activeDeadline = Date().addingTimeInterval(2)
        while Date() < activeDeadline, controller.state != .active {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.state, .active)

        XCTAssertTrue(
            recordedCommands().contains("stream --udid \(Self.udid) --format avcc --fps 30 --scale 2"),
            "默认参数应为 --fps 30 --scale 2（设计 §8 实测）"
        )

        controller.stop()
        XCTAssertFalse(controller.isRunning)
        // state 发布走主线程异步派发，轮询等待落定
        let idleDeadline = Date().addingTimeInterval(2)
        while Date() < idleDeadline, controller.state != .idle {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(waitForRecord(containing: "INT"), "stop 应发送 SIGINT，假 baguette 记录后退出")
    }

    // MARK: - 异常退出

    func testUnexpectedExitReportsEndedAndStderrLine() throws {
        let crashScript = root.appendingPathComponent("baguette-crash")
        try writeScript(at: crashScript, contents: """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        echo "stream error boom" >&2
        exit 3
        """)

        let controller = BaguetteController()
        let ended = expectation(description: "退出回调")
        let stderrLine = expectation(description: "stderr 行回调")
        controller.onState = { state in
            if case .ended(let reason) = state {
                XCTAssertFalse(reason.isEmpty, "ended 应带原因（stderr 行或退出码）")
                ended.fulfill()
            }
        }
        controller.onStderrLine = { line in
            if line.contains("stream error boom") {
                stderrLine.fulfill()
            }
        }

        controller.start(udid: Self.udid, baguette: crashScript)
        wait(for: [ended, stderrLine], timeout: 5)
        XCTAssertFalse(controller.isRunning)
    }

    // MARK: - 二进制定位

    func testLocateBinaryPrefersBundleThenPATH() throws {
        let bundleResourceURL = root.appendingPathComponent("MockApp.app/Contents/Resources")
        try FileManager.default.createDirectory(
            at: bundleResourceURL.appendingPathComponent("Helpers"),
            withIntermediateDirectories: true
        )
        let bundleBinary = bundleResourceURL.appendingPathComponent("Helpers/Baguette")
        try writeScript(at: bundleBinary, contents: "#!/bin/sh\n")

        let pathDirectory = root.appendingPathComponent("pathdir")
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        let pathBinary = pathDirectory.appendingPathComponent("Baguette")
        try writeScript(at: pathBinary, contents: "#!/bin/sh\n")

        XCTAssertEqual(
            BaguetteController.locateBinary(bundleResourceURL: bundleResourceURL, searchPath: pathDirectory.path),
            bundleBinary,
            "Bundle 内 Helpers/Baguette 优先（内嵌打包）"
        )
        XCTAssertEqual(
            BaguetteController.locateBinary(bundleResourceURL: nil, searchPath: pathDirectory.path),
            pathBinary,
            "无 Bundle 候选时回退 PATH"
        )
        XCTAssertNil(
            BaguetteController.locateBinary(bundleResourceURL: nil, searchPath: root.appendingPathComponent("empty").path),
            "都找不到返回 nil（基础档仍可用）"
        )
    }

    func testEnhancedTierRequiresSystemSupport() {
        XCTAssertFalse(
            BaguetteController.isEnhancedTierSupported(
                systemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 1)
            ),
            "macOS 15 以下不具备增强档门槛"
        )
    }

    // MARK: - 辅助

    private func recordedCommands() -> String {
        (try? String(contentsOf: recordFile, encoding: .utf8)) ?? ""
    }

    private func waitForRecord(containing text: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recordedCommands().contains(text) {
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

    /// 假 baguette stream：记录参数 → 分块回放 canned AVCC → 驻留直到 SIGINT。
    private func streamScript() -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        trap 'printf "INT\\n" >> "\(recordFile.path)"; exit 0' INT TERM
        i=0
        size=$(stat -f%z "\(cannedStream.path)")
        while [ $i -lt $size ]; do
          dd if="\(cannedStream.path)" bs=1 skip=$i count=96 2>/dev/null
          i=$((i + 96))
          sleep 0.02
        done
        sleep 30 &
        wait $!
        """
    }
}
