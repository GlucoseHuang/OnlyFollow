import Foundation
import SwiftData

/// 视频标题的 embedding 向量(本地设备缓存,不入 GitHub 同步快照)
///
/// 设计要点：
/// - `aid + modelName` 联合唯一：换模型（比如 text-embedding-v3 升 v4）时不会和旧向量撞
/// - `lastEmbeddedAt` 用于"标题变了"判定：VideoRecord.title 改了，重算这一条
/// - `embedding` 用 Data 存 [Float]（4 字节 × 维度数）；取出时用 `withUnsafeBytes` 强转
/// - 故意不参与 SyncSnapshot：向量是设备本地派生的"派生数据"，每台设备自己算一次就行，
///   而且 1024 维 × 4 字节 × 1000 视频 = 4MB，绑进 snapshot.json.gz 有点浪费
@Model
final class VideoEmbedding {
    @Attribute(.unique) var aid: Int
    /// 模型名(如 "text-embedding-v4"), 升级模型时用来区分老向量
    var modelName: String
    /// 向量维度(冗余存一下,避免反序列化时还得去查配置)
    var dimensions: Int
    /// embedding 字节流;解码时 Float32 数组长度 = dimensions
    var embedding: Data
    /// 这条向量对应的 VideoRecord.title;增量更新时如果 title 变了,就重算
    var titleSnapshot: String
    var lastEmbeddedAt: Date

    init(
        aid: Int,
        modelName: String,
        dimensions: Int,
        embedding: Data,
        titleSnapshot: String,
        lastEmbeddedAt: Date = .now
    ) {
        self.aid = aid
        self.modelName = modelName
        self.dimensions = dimensions
        self.embedding = embedding
        self.titleSnapshot = titleSnapshot
        self.lastEmbeddedAt = lastEmbeddedAt
    }

    /// 取出 embedding 为 Float32 数组(只读视图)
    /// - 故意不缓存,避免在 record 多处使用时持有大数组
    var floats: [Float] {
        let count = embedding.count / MemoryLayout<Float>.size
        return embedding.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: buf.baseAddress, count: count))
        }
    }
}
