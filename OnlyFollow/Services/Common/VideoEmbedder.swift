import Foundation
import SwiftData

/// 把 VideoRecord 里的标题喂给 EmbeddingService,结果写入 VideoEmbedding 表
///
/// 工作模式：
/// - runOnce(context:) 跑一次「找需要补的」+「调 API」+「写回」
/// - 启动时 / 后台 BGTask 都可以调
/// - 失败抛错,上层决定要不要在 UI 上提示
///
/// 触发条件（一项不满足就不重算）：
/// 1. VideoEmbedding 表里没这条 aid
/// 2. modelName 变了（用户升级了 embedding 模型）
/// 3. titleSnapshot 和 VideoRecord.title 不一致
///
/// 性能估算：
/// - 1000 个标题,单 batch=10, 100 批 × 0.4s = 40s + API 时间
/// - token 数大约 50K, 0.025 元左右(百炼 v4 价格)
/// - 增量更新只处理新增 / 标题变化的, 实际每天增量远小于全量
enum VideoEmbedder {
    /// 执行一次增量更新。返回这次新建/更新的条数
    @discardableResult
    static func runOnce(
        context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> Int {
        guard AppSettings.hasEmbeddingAPIKey else {
            AppLogger.info("VideoEmbedder: 未配置 embedding API key, 跳过")
            return 0
        }
        let modelName = AppSettings.embeddingModel
        let dimensions = AppSettings.embeddingDimensions

        // 1. 拉全量 VideoRecord + 对应 VideoEmbedding,做差集
        let allRecords = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        if allRecords.isEmpty {
            AppLogger.info("VideoEmbedder: 库里没视频, 跳过")
            return 0
        }
        let existingEmbeddings = (try? context.fetch(FetchDescriptor<VideoEmbedding>())) ?? []
        var embByAid: [Int: VideoEmbedding] = [:]
        for e in existingEmbeddings { embByAid[e.aid] = e }

        // 2. 找出需要重算的
        struct PendingItem {
            let aid: Int
            let title: String
        }
        var pending: [PendingItem] = []
        for r in allRecords {
            let need = embByAid[r.aid].map { $0.modelName != modelName || $0.titleSnapshot != r.title } ?? true
            if need {
                pending.append(PendingItem(aid: r.aid, title: r.title))
            }
        }

        if pending.isEmpty {
            AppLogger.info("VideoEmbedder: \(allRecords.count) 个视频全部已有向量, 跳过")
            return 0
        }
        AppLogger.info("VideoEmbedder: 共 \(allRecords.count) 个视频, 其中 \(pending.count) 个需要补/更新 embedding")

        // 3. 分批处理(每 50 个视频 = 5 个 API batch 一组), 每组完就 save 一次
        // - 这样 6256 个视频也能「先填一部分」, 用户能在 Settings 看到进度
        // - 单批失败: 跳过当前批, 继续后面的(不阻塞整次 run)
        let chunkSize = 50
        var totalWritten = 0
        let now = Date()
        for chunkStart in stride(from: 0, to: pending.count, by: chunkSize) {
            if Task.isCancelled {
                AppLogger.info("VideoEmbedder: 任务被取消, 已写 \(totalWritten)/\(pending.count)")
                return totalWritten
            }
            let chunkEnd = min(chunkStart + chunkSize, pending.count)
            let chunk = Array(pending[chunkStart..<chunkEnd])
            let titles = chunk.map(\.title)

            let vectors: [[Float]]
            do {
                vectors = try await EmbeddingService.shared.embed(titles)
            } catch {
                AppLogger.error("VideoEmbedder: 批 \(chunkStart)-\(chunkEnd) API 失败, 跳过: \(error.localizedDescription)")
                continue
            }
            guard vectors.count == chunk.count else {
                AppLogger.error("VideoEmbedder: 批 \(chunkStart) 返回数量不匹配 (got \(vectors.count), want \(chunk.count))")
                continue
            }

            // 写这一批到 SwiftData
            for (i, item) in chunk.enumerated() {
                let floats = vectors[i]
                let data: Data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
                if let existing = embByAid[item.aid] {
                    existing.modelName = modelName
                    existing.dimensions = floats.count
                    existing.embedding = data
                    existing.titleSnapshot = item.title
                    existing.lastEmbeddedAt = now
                } else {
                    let emb = VideoEmbedding(
                        aid: item.aid,
                        modelName: modelName,
                        dimensions: floats.count,
                        embedding: data,
                        titleSnapshot: item.title,
                        lastEmbeddedAt: now
                    )
                    context.insert(emb)
                }
            }
            do {
                try context.save()
                totalWritten += chunk.count
                // 每 100 个视频打一条 INFO 进度日志, 不会太吵
                if totalWritten % 100 == 0 || totalWritten == pending.count {
                    AppLogger.info("VideoEmbedder: 进度 \(totalWritten)/\(pending.count)")
                }
                onProgress?(totalWritten, pending.count)
            } catch {
                AppLogger.error("VideoEmbedder: 批 \(chunkStart) 保存失败: \(error.localizedDescription)")
                // 保存失败不 return, 继续后面的批
            }
        }
        AppLogger.info("VideoEmbedder: 完成, 写入 \(totalWritten)/\(pending.count) 条 embedding")
        return totalWritten
    }
}
