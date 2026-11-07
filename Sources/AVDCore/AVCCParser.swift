import Foundation

/// baguette stream（--format avcc）的一个分帧块。
/// wire 格式为 `[4 字节大端长度][1 字节 tag][payload]`，长度字段覆盖 tag 与 payload
/// （PoC 的 avcc_stats.py 按同口径解析实测码流，tag 0x01 avcC / 0x02 IDR / 0x03 delta / 0x04 JPEG seed）。
public struct AVCCChunk: Equatable, Sendable {
    public enum Tag: UInt8, Equatable, Sendable {
        case avcC = 0x01
        case idr = 0x02
        case delta = 0x03
        case jpeg = 0x04
    }

    public let tag: Tag
    public let payload: Data

    public init(tag: Tag, payload: Data) {
        self.tag = tag
        self.payload = payload
    }
}

/// 解析 baguette AVCC 分帧流。半包缓冲等待后续数据；
/// 长度非法（0 或超过单块上限）视为帧界丢失，整段丢弃等待重新对齐；
/// 未知 tag 按长度跳过（分帧自带边界，跳过后仍保持对齐）。
public struct AVCCParser {
    /// 单块长度上限，防止越界长度把缓冲区撑爆；超过即判定为失步。
    public static let maxChunkLength = 16 * 1024 * 1024

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func extract(_ chunk: Data) -> [AVCCChunk] {
        buffer.append(contentsOf: chunk)

        var chunks: [AVCCChunk] = []
        while buffer.count >= 5 {
            let length = (UInt32(buffer[0]) << 24)
                | (UInt32(buffer[1]) << 16)
                | (UInt32(buffer[2]) << 8)
                | UInt32(buffer[3])
            guard length >= 1, Int(length) <= Self.maxChunkLength else {
                buffer = []
                return chunks
            }
            let total = 4 + Int(length)
            if buffer.count < total {
                break // 截断：保留半包，等下一个 chunk 补齐
            }
            let tagByte = buffer[4]
            let payload = Data(buffer[5..<total])
            buffer.removeFirst(total)
            guard let tag = AVCCChunk.Tag(rawValue: tagByte) else {
                continue
            }
            chunks.append(AVCCChunk(tag: tag, payload: payload))
        }
        return chunks
    }

    /// 从 avcC（AVCDecoderConfigurationRecord）提取参数集（裸 NAL，SPS 在前、PPS 在后）。
    /// 记录截断时返回已完整读出的前缀；解析不到任何参数集返回空数组。
    public static func parameterSets(inAVCCConfig payload: Data) -> [Data] {
        let bytes = [UInt8](payload)
        // 头部 6 字节：4 字节配置 + lengthSizeMinusOne + numOfSequenceParameterSets
        guard bytes.count >= 6 else { return [] }

        var offset = 6
        var sets: [Data] = []
        let spsCount = Int(bytes[5] & 0x1F)
        for _ in 0..<spsCount {
            guard let set = Self.readNAL(at: &offset, bytes: bytes) else { return sets }
            sets.append(set)
        }
        guard offset < bytes.count else { return sets }
        let ppsCount = Int(bytes[offset])
        offset += 1
        for _ in 0..<ppsCount {
            guard let set = Self.readNAL(at: &offset, bytes: bytes) else { return sets }
            sets.append(set)
        }
        return sets
    }

    /// 读取一个 `[2 字节长度][NAL]` 参数集；越界返回 nil。
    private static func readNAL(at offset: inout Int, bytes: [UInt8]) -> Data? {
        guard offset + 2 <= bytes.count else { return nil }
        let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
        offset += 2
        guard offset + length <= bytes.count else { return nil }
        let nal = Data(bytes[offset..<(offset + length)])
        offset += length
        return nal
    }
}
