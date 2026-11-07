import XCTest
@testable import SimDeckCore

/// 按设计文档 §5.2 的"假可执行 + 参数记录"模式验证 baguette 子进程管理：
/// stream 默认参数、AVCC 回放解码、SIGINT 干净退出、异常退出回调与二进制定位；
/// input 会话的手势 JSON 写入与 ack 回读、失败 ack、影子警告；
/// describe-ui 的 screen 解析与 heal 的 outcome 解析。
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
            .appendingPathComponent("SimDeckBaguetteMock-\(UUID().uuidString)")
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

    /// 设置里的路径覆盖优先级最高（内嵌副本与 PATH 之前）。
    func testLocateBinaryPrefersOverridePath() throws {
        let bundleResourceURL = root.appendingPathComponent("MockApp.app/Contents/Resources")
        try FileManager.default.createDirectory(
            at: bundleResourceURL.appendingPathComponent("Helpers"),
            withIntermediateDirectories: true
        )
        try writeScript(at: bundleResourceURL.appendingPathComponent("Helpers/Baguette"), contents: "#!/bin/sh\n")

        let overrideDirectory = root.appendingPathComponent("overridedir")
        try FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
        let overrideBinary = overrideDirectory.appendingPathComponent("Baguette")
        try writeScript(at: overrideBinary, contents: "#!/bin/sh\n")

        XCTAssertEqual(
            BaguetteController.locateBinary(
                overridePath: overrideBinary.path,
                bundleResourceURL: bundleResourceURL,
                searchPath: nil
            ),
            overrideBinary,
            "覆盖路径优先于内嵌副本"
        )
        // 覆盖路径不可执行时照常回退内嵌副本。
        XCTAssertEqual(
            BaguetteController.locateBinary(
                overridePath: root.appendingPathComponent("missing").path,
                bundleResourceURL: bundleResourceURL,
                searchPath: nil
            ),
            bundleResourceURL.appendingPathComponent("Helpers/Baguette")
        )
    }

    /// 版本来自根命令的 `--version` 旗标（ArgumentParser CommandConfiguration(version:)）。
    func testVersionReadsVersionFlagOutput() throws {
        let versioned = root.appendingPathComponent("baguette-version")
        try writeScript(at: versioned, contents: "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"0.2.13\"; fi\n")
        XCTAssertEqual(BaguetteController.version(of: versioned), "0.2.13")

        let failing = root.appendingPathComponent("baguette-version-fail")
        try writeScript(at: failing, contents: "#!/bin/sh\nexit 1\n")
        XCTAssertNil(BaguetteController.version(of: failing), "读取失败返回 nil，版本仅作展示")

        let silent = root.appendingPathComponent("baguette-version-silent")
        try writeScript(at: silent, contents: "#!/bin/sh\n")
        XCTAssertNil(BaguetteController.version(of: silent), "空输出返回 nil")
    }

    func testEnhancedTierRequiresSystemSupport() {
        XCTAssertFalse(
            BaguetteController.isEnhancedTierSupported(
                systemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 1)
            ),
            "macOS 15 以下不具备增强档门槛"
        )
    }

    // MARK: - input 会话

    func testInputSessionSendsGestureJSONAndReadsAck() throws {
        let inputRecord = root.appendingPathComponent("input-record.txt")
        let script = root.appendingPathComponent("baguette-input")
        try writeScript(at: script, contents: """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "\(inputRecord.path)"
          printf '%s\\n' '{"ok":true}'
        done
        """)

        let session = BaguetteInputSession()
        defer { session.stop() }
        let acked = expectation(description: "ack 回读")
        var ack: BaguetteInputSession.Ack?
        session.onAck = {
            ack = $0
            acked.fulfill()
        }

        session.start(udid: Self.udid, baguette: script)
        XCTAssertEqual(session.udid, Self.udid)
        try session.send(.tap(x: 219, y: 478, width: 402, height: 874, duration: 0.05))
        wait(for: [acked], timeout: 5)
        XCTAssertEqual(ack?.ok, true)
        XCTAssertNil(ack?.error)
        XCTAssertTrue(waitForRecord(containing: "input --udid \(Self.udid)"), "input 子进程默认参数为 input --udid <udid>")

        // 逐字段核对写入 stdin 的手势 JSON（不依赖键序）
        let sent = try String(contentsOf: inputRecord, encoding: .utf8)
        let line = try XCTUnwrap(sent.split(separator: "\n").first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "tap")
        XCTAssertEqual(object["x"] as? Int, 219)
        XCTAssertEqual(object["y"] as? Int, 478)
        XCTAssertEqual(object["width"] as? Int, 402)
        XCTAssertEqual(object["height"] as? Int, 874)
        XCTAssertEqual(object["duration"] as? Double, 0.05)
    }

    func testInputSessionSurfacesRejectedAck() throws {
        let script = root.appendingPathComponent("baguette-reject")
        try writeScript(at: script, contents: """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' '{"ok":false,"error":"missing field: width"}'
        done
        """)

        let session = BaguetteInputSession()
        defer { session.stop() }
        let acked = expectation(description: "失败 ack")
        var ack: BaguetteInputSession.Ack?
        session.onAck = {
            ack = $0
            acked.fulfill()
        }

        session.start(udid: Self.udid, baguette: script)
        try session.send(.swipe(startX: 0, startY: 0, endX: 10, endY: 10, width: 402, height: 874, duration: 0.3))
        wait(for: [acked], timeout: 5)
        XCTAssertEqual(ack?.ok, false)
        XCTAssertEqual(ack?.error, "missing field: width")
    }

    /// AppModel.handleInputSessionEnded 的重启守卫依赖的不变式：
    /// 意外退出（handleProcessEnd）不清 udid，主动 stop 才清——否则重启工作项
    /// 的 `baguetteInput.udid == udid` 永假，恢复路径失效。
    func testInputSessionKeepsUDIDAfterUnexpectedExit() throws {
        let script = root.appendingPathComponent("baguette-die")
        try writeScript(at: script, contents: """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        echo "input died" >&2
        exit 3
        """)

        let session = BaguetteInputSession()
        let ended = expectation(description: "意外退出回调")
        var reason: String?
        session.onEnded = {
            reason = $0
            ended.fulfill()
        }

        session.start(udid: Self.udid, baguette: script)
        wait(for: [ended], timeout: 5)
        XCTAssertNotNil(reason, "意外退出应带原因（stderr 行或退出码）")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.udid, Self.udid, "意外退出不清 udid，重启守卫依赖它成立")
        session.stop()
        XCTAssertNil(session.udid, "主动 stop 清空 udid，onEnded 不再触发重启")
    }

    func testInputSessionDetectsShadowAdviceOnce() throws {
        let script = root.appendingPathComponent("baguette-shadow")
        try writeScript(at: script, contents: """
        #!/bin/sh
        printf '%s\\n' "Device Hub has attached to this simulator, which shadows the input surface baguette drives — touches and buttons may be dropped while reporting ok. Run baguette heal --udid \(Self.udid) to reclaim it (this restarts SpringBoard)." >&2
        while IFS= read -r line; do
          printf '%s\\n' '{"ok":true}'
        done
        """)

        let session = BaguetteInputSession()
        defer { session.stop() }
        let advised = expectation(description: "影子警告上报")
        var adviceCount = 0
        session.onShadowAdvice = {
            adviceCount += 1
            advised.fulfill()
        }

        session.start(udid: Self.udid, baguette: script)
        try session.send(.key(.home)) // 产生一次 ack，确认会话存活
        wait(for: [advised], timeout: 5)
        XCTAssertEqual(adviceCount, 1, "影子警告每次会话至多上报一次")
    }

    // MARK: - describe-ui 与 heal

    func testDescribeScreenReadsCannedScreenField() throws {
        let canned = root.appendingPathComponent("describe.json")
        try """
        {"children":[],"frame":{"height":874,"width":402,"x":0,"y":0},"role":"AXApplication",
         "screen":{"height":874,"orientation":"portrait","target":{"litPanel":"primary","pixelSize":{"height":2622,"width":1206},"screenId":1},"width":402}}
        """.write(to: canned, atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("baguette-describe")
        try writeScript(at: script, contents: """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        if [ "$1" = "describe-ui" ]; then
          cat "\(canned.path)"
        fi
        """)

        let size = try BaguetteController.describeScreen(udid: Self.udid, baguette: script)
        XCTAssertEqual(size.width, 402, "screen 字段是 device points，不是像素")
        XCTAssertEqual(size.height, 874)
        XCTAssertTrue(recordedCommands().contains("describe-ui --udid \(Self.udid)"))
    }

    func testHealParsesReclaimedAndUnshadowedOutcomes() throws {
        let reclaimedScript = root.appendingPathComponent("baguette-heal-reclaimed")
        try writeScript(at: reclaimedScript, contents: """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(recordFile.path)"
        printf '[baguette] Input surface reclaimed from Device Hub (SpringBoard restarted)\\n' >&2
        """)
        XCTAssertEqual(try BaguetteController.heal(udid: Self.udid, baguette: reclaimedScript), .reclaimed)
        XCTAssertTrue(recordedCommands().contains("heal --udid \(Self.udid)"))

        let unshadowedScript = root.appendingPathComponent("baguette-heal-unshadowed")
        try writeScript(at: unshadowedScript, contents: """
        #!/bin/sh
        printf '[baguette] Input surface is not shadowed by Device Hub — nothing to heal\\n' >&2
        """)
        XCTAssertEqual(try BaguetteController.heal(udid: Self.udid, baguette: unshadowedScript), .unshadowed)
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
