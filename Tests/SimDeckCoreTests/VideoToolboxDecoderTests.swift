import CoreMedia
import XCTest
@testable import SimDeckCore

/// 参照 H264AnnexBParserTests 思路：用 VideoToolbox 压缩会话产出真实 H.264，
/// 验证共用解码核心的配置、解码与失效路径。
final class VideoToolboxDecoderTests: XCTestCase {
    func testRoundTripDecodesEncoderOutput() throws {
        let stream = try TestH264Encoder.encode(width: 64, height: 48)

        let sets = AVCCParser.parameterSets(inAVCCConfig: stream.avcC)
        XCTAssertGreaterThanOrEqual(sets.count, 2, "avcC 应至少包含一个 SPS 与一个 PPS")

        let decoder = VideoToolboxDecoder()
        let size = try decoder.configure(parameterSets: sets)
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
        XCTAssertTrue(decoder.isConfigured)

        let firstFrame = expectation(description: "解码输出首帧")
        var decodedSize: CGSize?
        decoder.onFrame = { image, size in
            XCTAssertEqual(Int(image.width), 64)
            XCTAssertEqual(Int(image.height), 48)
            decodedSize = size
            firstFrame.fulfill()
        }
        XCTAssertTrue(decoder.decode(avcc: stream.idr))
        wait(for: [firstFrame], timeout: 5)
        XCTAssertEqual(decodedSize?.width, 64)
        XCTAssertEqual(decodedSize?.height, 48)

        // 第二帧（delta）也应正常出图
        let secondFrame = expectation(description: "解码输出第二帧")
        decoder.onFrame = { _, _ in secondFrame.fulfill() }
        XCTAssertTrue(decoder.decode(avcc: stream.delta))
        wait(for: [secondFrame], timeout: 5)
    }

    func testDecodeWithoutConfigureReturnsFalse() {
        let decoder = VideoToolboxDecoder()
        // 4 字节长度前缀 + NAL 头 0x65（IDR 切片）
        let sample = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00])
        XCTAssertFalse(decoder.decode(avcc: sample))
    }

    func testConfigureRejectsGarbageParameterSets() {
        let decoder = VideoToolboxDecoder()
        XCTAssertThrowsError(try decoder.configure(parameterSets: [
            Data([0x67, 0x00, 0x01, 0x02]),
            Data([0x68, 0x00, 0x01, 0x02])
        ]))
        XCTAssertFalse(decoder.isConfigured, "配置失败不应留下半初始化会话")
    }

    func testInvalidateRequiresReconfigure() throws {
        let stream = try TestH264Encoder.encode(width: 64, height: 48)
        let sets = AVCCParser.parameterSets(inAVCCConfig: stream.avcC)

        let decoder = VideoToolboxDecoder()
        try decoder.configure(parameterSets: sets)
        decoder.invalidate()
        XCTAssertFalse(decoder.isConfigured)
        XCTAssertFalse(decoder.decode(avcc: stream.idr))

        let size = try decoder.configure(parameterSets: sets)
        XCTAssertEqual(size.width, 64)
        XCTAssertTrue(decoder.isConfigured)
    }
}
