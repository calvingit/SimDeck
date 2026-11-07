import XCTest
@testable import SimDeckCore

/// 与 baguette wire 协议（v0.2.13，`baguette input` 的 JSON lines）逐字段比对：
/// 坐标一律 device points（不做像素换算），位置类手势必带 width/height，
/// duration 单位秒；key 走 `button` press；text 走 `type`。
final class IOSGestureCodableTests: XCTestCase {
    private func encodedJSON(_ gesture: IOSGesture) throws -> [String: Any] {
        let data = try JSONEncoder().encode(gesture)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testTapEncodesAllWireFields() throws {
        let json = try encodedJSON(.tap(x: 219, y: 478, width: 402, height: 874, duration: 0.05))
        XCTAssertEqual(json["type"] as? String, "tap")
        XCTAssertEqual(json["x"] as? Int, 219)
        XCTAssertEqual(json["y"] as? Int, 478)
        XCTAssertEqual(json["width"] as? Int, 402)
        XCTAssertEqual(json["height"] as? Int, 874)
        XCTAssertEqual(json["duration"] as? Double, 0.05)
        // 坐标必须是 device points 原值（poC 实测 screen 402×874 points / 1206×2622 px），
        // 不允许出现像素值。
        XCTAssertNotEqual(json["x"] as? Int, 1206)
    }

    func testSwipeEncodesStartEndAndSize() throws {
        let json = try encodedJSON(.swipe(
            startX: 219, startY: 760, endX: 219, endY: 190,
            width: 402, height: 874, duration: 0.3
        ))
        XCTAssertEqual(json["type"] as? String, "swipe")
        XCTAssertEqual(json["startX"] as? Int, 219)
        XCTAssertEqual(json["startY"] as? Int, 760)
        XCTAssertEqual(json["endX"] as? Int, 219)
        XCTAssertEqual(json["endY"] as? Int, 190)
        XCTAssertEqual(json["width"] as? Int, 402)
        XCTAssertEqual(json["height"] as? Int, 874)
        XCTAssertEqual(json["duration"] as? Double, 0.3)
    }

    func testPinchEncodesSpreadAndSizeWithoutDuration() throws {
        let json = try encodedJSON(.pinch(cx: 201, cy: 437, startSpread: 60, endSpread: 240, width: 402, height: 874))
        XCTAssertEqual(json["type"] as? String, "pinch")
        XCTAssertEqual(json["cx"] as? Int, 201)
        XCTAssertEqual(json["cy"] as? Int, 437)
        XCTAssertEqual(json["startSpread"] as? Int, 60)
        XCTAssertEqual(json["endSpread"] as? Int, 240)
        XCTAssertEqual(json["width"] as? Int, 402)
        XCTAssertEqual(json["height"] as? Int, 874)
        // 不编码 duration，服务端按 wire 默认值插值（0.6s）。
        XCTAssertNil(json["duration"])
    }

    func testKeyEncodesAsButtonPress() throws {
        let home = try encodedJSON(.key(.home))
        XCTAssertEqual(home["type"] as? String, "button")
        XCTAssertEqual(home["button"] as? String, "home")
        XCTAssertEqual(home["duration"] as? Double, 0)

        XCTAssertEqual(try encodedJSON(.key(.lock))["button"] as? String, "lock")
        XCTAssertEqual(try encodedJSON(.key(.volumeUp))["button"] as? String, "volume-up")
        XCTAssertEqual(try encodedJSON(.key(.volumeDown))["button"] as? String, "volume-down")
    }

    func testTextEncodesTypeCommand() throws {
        let json = try encodedJSON(.text("hello world"))
        XCTAssertEqual(json["type"] as? String, "type")
        XCTAssertEqual(json["text"] as? String, "hello world")
    }
}

/// BaguetteController 新增的解析辅助：describe-ui 的 screen 字段、ack 行、Device Hub 影子警告行。
final class BaguetteInputParsingTests: XCTestCase {
    /// 截取自 PoC 实测 fixture（/tmp/poc-scripts/describe27.json，iPhone 17 Pro）。
    private static let describe27Sample = """
    {"affordances":{},"children":[],"enabled":true,"frame":{"height":874,"width":402,"x":0,"y":0},
     "label":" ","role":"AXApplication",
     "screen":{"height":874,"orientation":"portrait",
               "target":{"litPanel":"primary","pixelSize":{"height":2622,"width":1206},"screenId":1},
               "width":402},
     "subrole":null,"title":null,"value":null}
    """

    func testParseScreenSizeReadsPointsFromScreenField() throws {
        let size = try BaguetteController.parseScreenSize(Self.describe27Sample)
        XCTAssertEqual(size.width, 402)
        XCTAssertEqual(size.height, 874)
    }

    func testParseScreenSizeRejectsMissingOrBrokenScreen() {
        XCTAssertThrowsError(try BaguetteController.parseScreenSize("{}"))
        XCTAssertThrowsError(try BaguetteController.parseScreenSize("not json"))
        XCTAssertThrowsError(try BaguetteController.parseScreenSize(#"{"screen":{"width":0,"height":874}}"#))
        XCTAssertThrowsError(try BaguetteController.parseScreenSize(#"{"screen":{"width":402}}"#))
    }

    func testParseAckReadsOkAndError() throws {
        let ok = try XCTUnwrap(BaguetteInputSession.parseAck(#"{"ok":true}"#))
        XCTAssertTrue(ok.ok)
        XCTAssertNil(ok.error)

        let failed = try XCTUnwrap(BaguetteInputSession.parseAck(#"{"ok":false,"error":"missing field: width"}"#))
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.error, "missing field: width")

        XCTAssertNil(BaguetteInputSession.parseAck("not json"))
        XCTAssertNil(BaguetteInputSession.parseAck(#"{"error":"no ok"}"#))
    }

    /// baguette v0.2.13 的影子 advisory 原文（DeviceHubAttachment.advisory，单行）。
    func testShadowAdviceLineDetection() {
        let advisory = """
        Device Hub has attached to this simulator, which shadows the input surface baguette drives \
        — touches and buttons may be dropped while reporting ok. \
        Run `baguette heal --udid 7118767B-5C7A-4AD8-A568-DD83F9DF6D0E` to reclaim it (this restarts SpringBoard).
        """
        XCTAssertTrue(BaguetteInputSession.isShadowAdviceLine(advisory))
        XCTAssertTrue(BaguetteInputSession.isShadowAdviceLine("run BAGUETTE HEAL to fix it"))
        // 普通日志行不误报
        XCTAssertFalse(BaguetteInputSession.isShadowAdviceLine("Input session started, reading from stdin"))
        XCTAssertFalse(BaguetteInputSession.isShadowAdviceLine("[baguette] start: format=avcc fps=30 scale=2"))
        XCTAssertFalse(BaguetteInputSession.isShadowAdviceLine("[baguette] [ax] hit-test sweep: probed=74 discovered=74"))
    }
}
