import XCTest
@testable import SimDeckCore

final class AVCCParserTests: XCTestCase {
    /// 按 wire 格式打包一个分帧块：[4 字节大端长度][1 字节 tag][payload]，长度含 tag 字节。
    private func frame(tag: UInt8, payload: Data) -> Data {
        TestH264Encoder.makeFrame(tag: tag, payload: payload)
    }

    // MARK: - 正常流

    func testExtractsAllTagTypes() {
        var parser = AVCCParser()
        let stream = frame(tag: 0x01, payload: Data([1, 2, 3]))
            + frame(tag: 0x02, payload: Data(repeating: 0xAB, count: 64))
            + frame(tag: 0x03, payload: Data([9]))
            + frame(tag: 0x04, payload: Data([0xFF, 0xD8]))

        let chunks = parser.extract(stream)

        XCTAssertEqual(chunks.map(\.tag), [.avcC, .idr, .delta, .jpeg])
        XCTAssertEqual(chunks[0].payload, Data([1, 2, 3]))
        XCTAssertEqual(chunks[1].payload, Data(repeating: 0xAB, count: 64))
        XCTAssertEqual(chunks[2].payload, Data([9]))
        XCTAssertEqual(chunks[3].payload, Data([0xFF, 0xD8]))
    }

    /// 连续流按 1 字节喂入，验证跨 chunk 的半包拼装不丢不乱。
    func testParsesAcrossByteByByteFeeding() {
        let idrPayload = Data(repeating: 0x11, count: 300)
        let deltaPayload = Data(repeating: 0x22, count: 7)
        var bytes = Array(frame(tag: 0x02, payload: idrPayload) + frame(tag: 0x03, payload: deltaPayload))

        var parser = AVCCParser()
        var collected: [AVCCChunk] = []
        while !bytes.isEmpty {
            collected += parser.extract(Data(bytes.prefix(1)))
            bytes.removeFirst()
        }

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected[0].tag, .idr)
        XCTAssertEqual(collected[0].payload, idrPayload)
        XCTAssertEqual(collected[1].tag, .delta)
        XCTAssertEqual(collected[1].payload, deltaPayload)
    }

    /// 大量帧按伪随机步长切块喂入，验证分帧计数与内容。
    func testContinuousStreamWithRandomSplits() {
        let expected: [(AVCCChunk.Tag, Data)] = (0..<50).map { i in
            let tag: AVCCChunk.Tag = i % 3 == 0 ? .idr : (i % 3 == 1 ? .delta : .avcC)
            let payload = Data((0..<(40 + i)).map { UInt8(($0 + i) & 0xFF) })
            return (tag, payload)
        }
        var stream = Data()
        for (tag, payload) in expected {
            stream += frame(tag: tag.rawValue, payload: payload)
        }

        var parser = AVCCParser()
        var collected: [AVCCChunk] = []
        var offset = 0
        var seed: UInt64 = 0x1234_5678
        while offset < stream.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let step = Int((seed >> 33) % 97) + 1
            let end = min(offset + step, stream.count)
            collected += parser.extract(stream.subdata(in: offset..<end))
            offset = end
        }

        XCTAssertEqual(collected.count, expected.count)
        for (chunk, (tag, payload)) in zip(collected, expected) {
            XCTAssertEqual(chunk.tag, tag)
            XCTAssertEqual(chunk.payload, payload)
        }
    }

    // MARK: - 截断

    func testTruncatedTailHoldsBackUntilComplete() {
        var parser = AVCCParser()
        let full = frame(tag: 0x02, payload: Data(repeating: 9, count: 10))
        let truncated = full.prefix(full.count - 3)

        let first = parser.extract(Data(truncated))
        XCTAssertTrue(first.isEmpty, "截断块不应提前产出")

        let second = parser.extract(Data(full.suffix(3)))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].tag, .idr)
        XCTAssertEqual(second[0].payload, Data(repeating: 9, count: 10))
    }

    func testTruncatedHeaderYieldsNothing() {
        var parser = AVCCParser()
        let chunks = parser.extract(Data([0x00, 0x00, 0x00])) // 不足 4 字节长度头
        XCTAssertTrue(chunks.isEmpty)
    }

    // MARK: - 长度越界

    /// 非法长度判定发生在凑满 5 字节头时：触发时把缓冲整段丢弃（坏头之后的数据一并视为失步），
    /// 后续 extract 调用从新数据重新对齐。
    func testLengthZeroDropsBufferAndResyncs() {
        var parser = AVCCParser()
        let good = frame(tag: 0x02, payload: Data([1, 2, 3]))
        let bad = Data([0x00, 0x00, 0x00, 0x00]) // 长度 0：帧界已丢失

        XCTAssertTrue(parser.extract(bad).isEmpty)
        XCTAssertTrue(parser.extract(good).isEmpty, "坏头之后的数据一并丢弃，等待重新对齐")
        let chunks = parser.extract(good) // 重新对齐后的数据正常解析
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].tag, .idr)
        XCTAssertEqual(chunks[0].payload, Data([1, 2, 3]))
    }

    func testOversizedLengthDropsBufferAndResyncs() {
        var parser = AVCCParser()
        let good = frame(tag: 0x03, payload: Data([7]))
        var bad = Data()
        let length = UInt32(AVCCParser.maxChunkLength + 1).bigEndian
        withUnsafeBytes(of: length) { bad.append(contentsOf: $0) }
        bad.append(0x02)

        let mixed = parser.extract(bad + good)
        XCTAssertTrue(mixed.isEmpty, "越界长度触发时整段丢弃缓冲")
        let chunks = parser.extract(good)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].tag, .delta)
        XCTAssertEqual(chunks[0].payload, Data([7]))
    }

    func testUnknownTagIsSkippedAndKeepsAlignment() {
        var parser = AVCCParser()
        let unknown = frame(tag: 0x7F, payload: Data([1, 2]))
        let known = frame(tag: 0x02, payload: Data([5]))

        let chunks = parser.extract(unknown + known)

        XCTAssertEqual(chunks.count, 1, "未知 tag 按长度跳过，不影响后续帧界")
        XCTAssertEqual(chunks[0].tag, .idr)
        XCTAssertEqual(chunks[0].payload, Data([5]))
    }

    // MARK: - avcC 参数集

    func testParameterSetsFromAVCCConfig() {
        let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0x9A, 0x80])
        let pps1 = Data([0x68, 0xCA, 0xF0, 0x84])
        let pps2 = Data([0x68, 0xCB])
        var record = Data([0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1]) // 头 6 字节：1 个 SPS、4 字节长度前缀
        record.append(UInt8(sps.count >> 8))
        record.append(UInt8(sps.count & 0xFF))
        record.append(sps)
        record.append(0x02) // 2 个 PPS
        for pps in [pps1, pps2] {
            record.append(UInt8(pps.count >> 8))
            record.append(UInt8(pps.count & 0xFF))
            record.append(pps)
        }

        let sets = AVCCParser.parameterSets(inAVCCConfig: record)

        XCTAssertEqual(sets, [sps, pps1, pps2])
    }

    func testParameterSetsWithTruncatedRecordReturnsCompletePrefix() {
        let sps = Data([0x67, 0x42, 0xC0])
        var record = Data([0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1])
        record.append(UInt8(sps.count >> 8))
        record.append(UInt8(sps.count & 0xFF))
        record.append(sps)
        record.append(0x01) // 声称 1 个 PPS
        record.append(0x00)
        record.append(0x10) // 声称 16 字节，但记录到此截断

        let sets = AVCCParser.parameterSets(inAVCCConfig: record)

        XCTAssertEqual(sets, [sps], "PPS 截断时应返回已完整的 SPS")
    }

    func testParameterSetsRejectsTooShortRecord() {
        XCTAssertTrue(AVCCParser.parameterSets(inAVCCConfig: Data([1, 2, 3])).isEmpty)
        XCTAssertTrue(AVCCParser.parameterSets(inAVCCConfig: Data()).isEmpty)
    }
}
