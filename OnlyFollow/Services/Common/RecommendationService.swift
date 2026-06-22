import Foundation
import SwiftData

/// 「播完下一个」推荐服务
///
/// 入口：
/// - `recommendForLocalVector(currentVideo:in:limit:)` — 用本地 embedding 算 top N
/// - `recommendForDeepSeek(currentVideo:in:limit:)` — 把标题列表发给 DeepSeek, 让它挑
///
/// 通用行为：
/// - 输入视频本身从候选里排除
/// - 候选不够时（库里视频太少）返回空数组,让上层自己处理"空态"
/// - 候选都没有 embedding 时（VideoEmbedder 还没跑过）先尝试跑一次
struct RecommendationService {
    /// 候选视频的最小数量。低于这个值直接返回 [], 不浪费 API
    static let minCandidateCount = 5

    // MARK: - 本地向量

    enum RecommendError: LocalizedError {
        case noCandidates
        case noEmbeddings
        case embeddingAPI(String)
        case deepseekAPI(String)
        case deepseekParse

        var errorDescription: String? {
            switch self {
            case .noCandidates: return "本地库视频数量过少, 无法推荐"
            case .noEmbeddings: return "本地向量库为空, 请先在设置里配置 embedding API 并等待后台建库"
            case .embeddingAPI(let s): return "Embedding 失败: \(s)"
            case .deepseekAPI(let s): return "DeepSeek 调用失败: \(s)"
            case .deepseekParse: return "DeepSeek 返回的标题列表无法解析"
            }
        }
    }

    /// 用本地 embedding 推荐 top N 视频
    /// - 工作流：
    ///   1. 确保 VideoEmbedding 表里至少有大部分视频的向量（必要时同步跑一次 VideoEmbedder.runOnce）
    ///   2. 算 currentVideo 标题的 embedding
    ///   3. 余弦相似度对所有候选打分
    ///   4. 过滤掉当前 aid, 取 top N
    static func recommendForLocalVector(
        currentVideo: VideoItem,
        in context: ModelContext,
        limit: Int? = nil
    ) async throws -> [VideoItem] {
        let n = limit ?? AppSettings.recommendCount
        guard AppSettings.hasEmbeddingAPIKey else {
            throw RecommendError.embeddingAPI("未配置 embedding API key")
        }

        // 1. 拉全量 VideoRecord
        let allRecords = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        let candidates = allRecords.filter { $0.aid != currentVideo.aid }
        guard candidates.count >= minCandidateCount else {
            throw RecommendError.noCandidates
        }

        // 2. 拿 embedding 表
        // - 故意不同步调 runOnce: 库很大(几千个视频)时一次跑完要几分钟,
        //   而推荐结果要"快播完前算好", 等不了那么久
        // - 表空时只 kick off 一次后台建库, 然后立刻返回 noEmbeddings
        //   上层会展示"暂无推荐"页面, 几分钟后用户回来重看一次就能用了
        let allEmbeddings = (try? context.fetch(FetchDescriptor<VideoEmbedding>())) ?? []
        if allEmbeddings.isEmpty {
            AppLogger.info("Recommendation: VideoEmbedding 表为空, kick off 后台建库, 本次直接返回空")
            Self.kickoffBackgroundEmbedIfNeeded()
            throw RecommendError.noEmbeddings
        }
        let embByAid: [Int: VideoEmbedding] = Dictionary(uniqueKeysWithValues: allEmbeddings.compactMap { e in
            (e.aid, e)
        })

        // 4. 算 current 的向量
        let queryVector: [Float]
        do {
            queryVector = try await EmbeddingService.shared.embedOne(currentVideo.title)
        } catch {
            throw RecommendError.embeddingAPI(error.localizedDescription)
        }
        guard !queryVector.isEmpty else { throw RecommendError.embeddingAPI("query embedding 为空") }

        // 5. 算每个候选的相似度
        struct Scored {
            let record: VideoRecord
            let score: Double
        }
        var scored: [Scored] = []
        for record in candidates {
            guard let emb = embByAid[record.aid] else { continue }
            let v = emb.floats
            guard v.count == queryVector.count else { continue }
            let s = cosineSimilarity(queryVector, v)
            scored.append(Scored(record: record, score: s))
        }
        guard !scored.isEmpty else { throw RecommendError.noEmbeddings }

        // 6. 排序: 分数降序
        scored.sort { $0.score > $1.score }

        // 7. 转 VideoItem
        return Array(scored.prefix(n)).map { $0.record.toVideoItem() }
    }

    // MARK: - DeepSeek

    /// 让 DeepSeek 从候选里挑 N 个最相关的
    /// - 工作流：
    ///   1. 拉全量 VideoRecord(排除当前)
    ///   2. 拼 prompt：system 说任务,user 给当前标题 + 候选标题列表(用 index 标识)
    ///   3. 解析返回的 index 列表
    /// - 失败时直接抛错,上层决定是否回退
    static func recommendForDeepSeek(
        currentVideo: VideoItem,
        in context: ModelContext,
        limit: Int? = nil
    ) async throws -> [VideoItem] {
        let n = limit ?? AppSettings.recommendCount
        guard AppSettings.hasDeepSeekAPIKey else {
            throw RecommendError.deepseekAPI("未配置 DeepSeek API key")
        }
        let allRecords = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        let candidates = allRecords.filter { $0.aid != currentVideo.aid }
        guard candidates.count >= minCandidateCount else {
            throw RecommendError.noCandidates
        }

        // 用 (idx, title) tuple 浅拷贝必要字段,避免 prompt 撑爆
        let minis: [(idx: Int, aid: Int, title: String)] = candidates.enumerated().map {
            (idx: $0.offset, aid: $0.element.aid, title: $0.element.title)
        }
        let recordsByAid: [Int: VideoRecord] = Dictionary(uniqueKeysWithValues: candidates.map { ($0.aid, $0) })

        let indices = try await callDeepSeekInner(
            currentTitle: currentVideo.title,
            candidates: minis.map { ($0.idx, $0.title) },
            limit: n
        )
        guard !indices.isEmpty else { throw RecommendError.deepseekParse }

        var result: [VideoItem] = []
        for idx in indices {
            guard idx >= 0, idx < minis.count else { continue }
            if let r = recordsByAid[minis[idx].aid] {
                result.append(r.toVideoItem())
            }
        }
        return result
    }

    // MARK: - Private

    /// 余弦相似度
    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }

    /// 调用 DeepSeek Chat Completions, 让它返回相关 top N 的 index 数组
    private static func callDeepSeekInner(
        currentTitle: String,
        candidates: [(Int, String)],
        limit: Int
    ) async throws -> [Int] {
        let systemPrompt = """
        你是视频推荐助手。根据用户当前看的视频标题, 从候选视频列表里挑出最相关的 \(limit) 个。
        只返回 JSON 数组, 元素是候选的 index(0-based), 按相关度从高到低排, 不要任何其他文字、解释、markdown 标记。
        例如: [3, 0, 7]
        """
        // 拼候选列表
        var userContent = "当前视频标题: \(currentTitle)\n\n候选视频(每行: <index>\\t<标题>):\n"
        for (idx, title) in candidates {
            userContent += "\(idx)\t\(title)\n"
        }

        let urlStr = AppSettings.deepseekBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        guard let url = URL(string: urlStr) else {
            throw RecommendError.deepseekAPI("invalid baseURL: \(urlStr)")
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Request: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let stream: Bool
        }
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        struct Response: Decodable {
            let choices: [Choice]
        }

        let body = Request(
            model: AppSettings.deepseekModel,
            messages: [
                Message(role: "system", content: systemPrompt),
                Message(role: "user", content: userContent)
            ],
            temperature: 0.2,
            stream: false
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AppSettings.deepseekAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RecommendError.deepseekAPI("HTTP \(code): \(body.prefix(200))")
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RecommendError.deepseekAPI("parse failed: \(error.localizedDescription)")
        }
        guard let content = decoded.choices.first?.message.content else {
            throw RecommendError.deepseekParse
        }
        let s = content
        // 解析 [3, 0, 7] 这种纯 JSON
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 简单清洗：去掉可能包着的 ```json ... ``` 或多余文字
        let cleaned: String
        if let lBracket = trimmed.firstIndex(of: "["), let rBracket = trimmed.lastIndex(of: "]") {
            cleaned = String(trimmed[lBracket...rBracket])
        } else {
            cleaned = trimmed
        }
        guard let data = cleaned.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Int] else {
            throw RecommendError.deepseekParse
        }
        return Array(arr.prefix(limit))
    }

    // MARK: - 后台建库触发器(去重)

    private static var embedKickoffInFlight: Bool = false

    /// 在后台启一次 VideoEmbedder.runOnce。如果已经有一次在跑就不再启。
    /// - 用 static var 简单去重(单 app 内, 不跨进程同步)
    /// - 容器来自 OnlyFollowApp.sharedContainer
    static func kickoffBackgroundEmbedIfNeeded() {
        guard !embedKickoffInFlight else { return }
        embedKickoffInFlight = true
        AppLogger.info("Recommendation: 启动后台建库 task")
        Task.detached(priority: .background) {
            defer {
                Task { @MainActor in
                    embedKickoffInFlight = false
                }
            }
            let ctx = ModelContext(OnlyFollowApp.sharedContainer)
            do {
                let n = try await VideoEmbedder.runOnce(context: ctx)
                AppLogger.info("Recommendation: 后台建库完成, 写入 \(n) 条")
            } catch {
                AppLogger.error("Recommendation: 后台建库失败: \(error.localizedDescription)")
            }
        }
    }
}
