import Foundation

/// SyncSnapshot <-> 二进制数据的编解码层
///
/// 文件格式（远端存什么字节）:
/// - 新格式:  1 字节 magic `0xCE` + Apple NSData 压缩后的 raw deflate 数据
///            magic 是我们自己定义的标记;JSON 的合法首字节只有 `{` (0x7B) 和 `[` (0x5B),
///            永远不会和 0xCE 撞,所以可以无损区分
/// - 旧格式:  原始 JSON 字节(改这个改动之前写入的快照)
///            用首字节是不是 `{`/`[` 来识别,继续兼容
///
/// 为什么用这个组合:
/// - 压缩:实测 4071 视频 / 8 UP 主的快照,明文 3.3MB → 135KB ≈ 24x;从国内拉 GitHub 关键路径
/// - Apple 的 NSData.compressed(using: .zlib) 输出的不是 RFC 1950 标准 zlib(没有 0x78 头),
///   而是 raw deflate 帧,首字节会随内容变。所以必须自己加 magic,不能靠 deflate 头识别。
/// - 解压端按 magic / `{`/`[` 走不同分支,旧数据继续能读;首次上传新格式即可
enum SyncCodec {
    /// 压缩文件的 magic 首字节(自己定,只要不和 JSON 合法首字节撞即可)
    static let compressedMagic: UInt8 = 0xCE

    /// 编码:JSON + zlib 压缩 + magic 前缀
    static func encode(_ snapshot: SyncSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(snapshot)
        guard let compressed = try? (json as NSData).compressed(using: .zlib) as Data? else {
            throw SyncCodecError.compressionFailed
        }
        var out = Data([compressedMagic])
        out.append(compressed)
        return out
    }

    /// 解码:按首字节分支
    /// - `0xCE` → 去掉 magic 后走解压
    /// - `{`/`[` → 旧版明文 JSON,直接解(向后兼容)
    /// - 其它 → 当损坏处理
    static func decode(_ data: Data) throws -> SyncSnapshot {
        let json: Data
        if data.first == compressedMagic {
            guard let decompressed = try? (data.dropFirst() as NSData).decompressed(using: .zlib) as Data? else {
                throw SyncCodecError.decompressionFailed
            }
            json = decompressed
        } else if data.first == 0x7B /* { */ || data.first == 0x5B /* [ */ {
            // 旧版未压缩 JSON
            json = data
        } else {
            // 不认识的格式(损坏 / 截断 / 写错的文件),别静默吞
            let preview = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            AppLogger.error("SyncCodec.decode: unknown file format (first bytes: \(preview))")
            throw SyncCodecError.unknownFormat
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SyncSnapshot.self, from: json)
        } catch {
            let preview = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            AppLogger.error("SyncCodec.decode: JSON decode failed (first bytes: \(preview)): \(error.localizedDescription)")
            throw error
        }
    }
}

enum SyncCodecError: LocalizedError {
    case compressionFailed
    case decompressionFailed
    case unknownFormat

    var errorDescription: String? {
        switch self {
        case .compressionFailed: return "同步数据压缩失败"
        case .decompressionFailed: return "同步数据解压失败"
        case .unknownFormat: return "同步文件格式无法识别(可能被截断或损坏)"
        }
    }
}
