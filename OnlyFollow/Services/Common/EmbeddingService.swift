import Foundation

/// Embedding 客户端（兼容 OpenAI / 阿里云百炼 compatible-mode）
///
/// 为什么放成 actor：
/// - 多个 VideoEmbedder 任务可能并发请求，要串行化限流
/// - 失败的请求要重试，集中放一处好做
///
/// 协议兼容性：
/// - POST {baseURL}/embeddings
/// - Headers: Authorization: Bearer {apiKey}
///
/// Request:
/// ```json
/// { "model": "text-embedding-v4", "input": ["a","b"], "dimensions": 1024, "encoding_format": "float" }
/// ```
/// Response:
/// ```json
/// { "data": [ { "index": 0, "embedding": [0.1, ...] }, ... ] }
/// ```
actor EmbeddingService {
    static let shared = EmbeddingService()

    /// 每次请求最大文本数（参考百炼官方建议，OpenAI 同步接口官方限制是 2048 条）
    let batchSize: Int = 10
    /// 两次请求之间最小间隔，避免触发限流
    private let requestInterval: TimeInterval = 0.4
    /// 失败重试次数
    private let maxRetries: Int = 3
    private var lastRequestTime: Date = .distantPast
    private let session: URLSession

    private struct EmbeddingsRequest: Encodable {
        let model: String
        let input: [String]
        let dimensions: Int
        let encoding_format: String = "float"
    }

    private struct EmbeddingsResponse: Decodable {
        struct Item: Decodable { let index: Int; let embedding: [Float] }
        let data: [Item]
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum EmbeddingError: LocalizedError {
        case notConfigured
        case httpStatus(Int, body: String)
        case parseFailed(String)
        case returnedMismatch(expected: Int, got: Int)
        case rateLimited
        case authFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "未配置 Embedding API key"
            case .httpStatus(let code, let body): return "Embedding 接口 HTTP \(code): \(body.prefix(200))"
            case .parseFailed(let msg): return "Embedding 响应解析失败: \(msg)"
            case .returnedMismatch(let e, let g): return "Embedding 返回数量与请求不一致 (expected=\(e), got=\(g))"
            case .rateLimited: return "Embedding 接口限流"
            case .authFailed: return "Embedding API key 无效(401)"
            }
        }
    }

    /// 批量计算 embedding。返回顺序与 inputs 一致
    /// - 内部按 batchSize 分批,每批间隔 requestInterval
    /// - 单批失败抛错,上层根据需要降级(全量失败的话,本次 embed 任务标记未完成,下次再试)
    func embed(_ inputs: [String]) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        guard AppSettings.hasEmbeddingAPIKey else { throw EmbeddingError.notConfigured }

        var results: [[Float]] = []
        results.reserveCapacity(inputs.count)

        for batchStart in stride(from: 0, to: inputs.count, by: batchSize) {
            let end = min(batchStart + batchSize, inputs.count)
            let batch = Array(inputs[batchStart..<end])
            let batchResult = try await callOnce(batch)
            // 调用方可能传了 0 长度字符串,某些 provider 会拒;这里跳过
            guard batchResult.count == batch.count else {
                throw EmbeddingError.returnedMismatch(expected: batch.count, got: batchResult.count)
            }
            results.append(contentsOf: batchResult)

            // 批间间隔(最后一批不睡)
            if end < inputs.count {
                try? await Task.sleep(for: .milliseconds(Int(requestInterval * 1000)))
            }
        }
        return results
    }

    /// 单独计算一条(查询当前视频标题用)
    func embedOne(_ text: String) async throws -> [Float] {
        let r = try await embed([text])
        return r.first ?? []
    }

    // MARK: - Private

    private func callOnce(_ inputs: [String]) async throws -> [[Float]] {
        let urlStr = AppSettings.embeddingBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/embeddings"
        guard let url = URL(string: urlStr) else {
            throw EmbeddingError.parseFailed("invalid baseURL: \(urlStr)")
        }

        let body = EmbeddingsRequest(
            model: AppSettings.embeddingModel,
            input: inputs,
            dimensions: AppSettings.embeddingDimensions
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AppSettings.embeddingAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        var lastError: Error?
        for attempt in 0..<maxRetries {
            // 限流
            let elapsed = Date().timeIntervalSince(lastRequestTime)
            if elapsed < requestInterval {
                try? await Task.sleep(for: .milliseconds(Int((requestInterval - elapsed) * 1000)))
            }
            lastRequestTime = Date()

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw EmbeddingError.parseFailed("not an HTTP response")
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw EmbeddingError.authFailed
                }
                if http.statusCode == 429 {
                    // 退避后重试
                    let wait = Double(attempt + 1) * 2
                    AppLogger.info("Embedding: 429 限流, 等待 \(wait)s 后重试")
                    try? await Task.sleep(for: .seconds(wait))
                    lastError = EmbeddingError.rateLimited
                    continue
                }
                if !(200..<300).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw EmbeddingError.httpStatus(http.statusCode, body: body)
                }

                let decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
                // 按 index 排序(虽然一般 API 都会按输入顺序返回, 保险起见排一下)
                let sorted = decoded.data.sorted { $0.index < $1.index }
                return sorted.map(\.embedding)
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let wait = Double(attempt + 1)
                    AppLogger.info("Embedding: 重试(\(attempt + 1)/\(maxRetries)) - \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        }
        throw lastError ?? EmbeddingError.parseFailed("unknown error")
    }
}
