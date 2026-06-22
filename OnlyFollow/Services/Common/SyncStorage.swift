import Foundation

/// 同步存储层 — GitHub 私有 repo 后端
///
/// 为什么用 GitHub:
/// - Student Developer Pack 送的 GitHub Pro,私有 repo 无限
/// - 私有 repo Contents API 单文件上限 100 MB,重度使用场景也够
/// - 不用装 SDK,直接 URLSession
/// - 调试时能直接在 GitHub 网页看 snapshot.json.gz
///
/// 同步文件格式:
/// - 路径:`snapshot.json.gz` (Gzip 压缩的 JSON 快照)
/// - 内容:SyncCodec.encode() 的输出
/// - 存储:GitHub 私有 repo 顶层
///
/// 并发安全:
/// - 写之前 GET 拿当前 SHA
/// - PUT 带上 SHA(更新现有文件)或省略(创建新文件)
/// - 422 sha_mismatch 时再 GET 一次重试一次
///
/// 错误语义:
/// - 404:文件不存在(首次同步,readSnapshot 返回 nil)
/// - 401:token 无效
/// - 422:sha 不匹配(另一台设备同时写了),自动重试
/// - 5xx/网络:抛错,SyncCoordinator 切到 .error 状态
final class SyncStorage: NSObject, @unchecked Sendable {
    static let shared = SyncStorage()

    /// 同步文件名(放在 repo 根目录)
    static let snapshotFileName = "snapshot.json"

    /// 状态变化(UI 用)
    static let stateChangeNotification = Notification.Name("SyncStorage.stateChange")

    /// 保留以备将来切换到带 listener 的后端(iCloud 之类)
    static let remoteChangeNotification = Notification.Name("SyncStorage.remoteChange")

    /// UserDefaults key
    private enum Keys {
        static let token = "sync.github.token"
        static let repo = "sync.github.repo"  // 格式: "owner/repo"
        static let deviceID = "sync.deviceID"
        static let hasCompletedInitialPull = "sync.hasCompletedInitialPull"
    }

    enum Availability: Equatable {
        /// GitHub 配置完整且可用
        case available
        /// 用户还没在设置页填 token / repo
        case unavailable(reason: String)
        /// 还没初始化完
        case unknown
    }

    /// 当前后端的可用性
    private(set) var availability: Availability = .unknown {
        didSet {
            NotificationCenter.default.post(name: Self.stateChangeNotification, object: self)
        }
    }

    /// 设备 ID(首次启动生成,存 UserDefaults)
    /// 不是同步逻辑必需的(同步是 last-write-wins),但写进 snapshot 便于调试时识别
    private(set) var deviceID: String = "unknown"

    private let defaults = UserDefaults.standard

    /// 是否已经从云端成功"确认过状态"(合并了远端 / 远端为空 / 是本设备自己写的)
    /// - 用于防止"新设备配置 sync 后立刻上传空快照覆盖云端数据"的竞态
    /// - 流程:sync 配置好 → pullNow 跑完 → 才允许上传
    /// - 持久化到 UserDefaults;SettingsView.saveSyncConfig() 在改 token/repo 时重置
    /// - performUpload 检查此标志;pullNow 在所有"已确认远端状态"分支置 true
    private(set) var hasCompletedInitialPull: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedInitialPull) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedInitialPull) }
    }

    /// 标记为"已经确认过远端状态,可以放行上传了"
    /// - 调用时机：SyncCoordinator.pullNow 在合并成功 / 远端为空 / 是本设备自己写的三个分支
    /// - 注意：不在"readSnapshot 失败"或"merge 失败"分支调用 —— 失败时本机对远端一无所知,不能上传
    func markInitialPullCompleted() {
        hasCompletedInitialPull = true
    }

    /// 把"已确认过状态"的标志重置回 false
    /// - 调用时机：SettingsView.saveSyncConfig()（用户改了 token / repo 重新配置时）
    /// - 之后必须再跑一次 pullNow 才能继续上传；防止"换 sync 后端后立刻用旧上下文推空数据"
    func resetHasCompletedInitialPull() {
        hasCompletedInitialPull = false
    }

    private override init() {
        super.init()
        // 恢复或生成 deviceID
        if let saved = defaults.string(forKey: Keys.deviceID) {
            self.deviceID = saved
        } else {
            let new = "ios-" + UUID().uuidString.prefix(8).lowercased()
            self.deviceID = new
            defaults.set(new, forKey: Keys.deviceID)
        }
        recomputeAvailability()
    }

    /// 启动 — 无 observer
    /// 同步触发完全靠 SyncCoordinator 的 debounce / foreground pull
    func start() {
        recomputeAvailability()
        AppLogger.info("SyncStorage: GitHub backend, repo=\(repoPath ?? "未配置")")
    }

    func stop() {}

    /// 配置变更后,UI 调用这个让 availability 立即刷新
    func settingsChanged() {
        recomputeAvailability()
    }

    /// 重新计算 availability
    private func recomputeAvailability() {
        if let path = repoPath, !path.isEmpty,
           let token = githubToken, !token.isEmpty {
            availability = .available
        } else {
            availability = .unavailable(reason: "未配置 GitHub token / repo(在 设置 → 数据同步 中填写)")
        }
    }

    // MARK: - 配置

    /// GitHub Personal Access Token
    /// - 用 classic PAT,scope `repo` 即可
    /// - 存在 UserDefaults(明文);iOS 沙盒保护
    var githubToken: String? {
        get { defaults.string(forKey: Keys.token) }
        set {
            defaults.set(newValue, forKey: Keys.token)
            recomputeAvailability()
        }
    }

    /// 仓库路径,格式 "owner/repo"
    var repoPath: String? {
        get { defaults.string(forKey: Keys.repo) }
        set {
            defaults.set(newValue, forKey: Keys.repo)
            recomputeAvailability()
        }
    }

    // MARK: - 读 / 写 (async)

    /// 读取快照
    /// - 返回 nil 表示云端没文件(首次同步正常情况)
    /// - 401 / 网络错误抛 SyncStorageError
    ///
    /// GitHub Contents API:
    /// - 小文件 (<1MB):默认 GET 返回 JSON wrapper, content 字段是 base64
    /// - 大文件 (>=1MB):默认 GET 返回 422;必须用 `Accept: application/vnd.github.v3.raw`
    ///                  才会返回 raw 文件内容;raw 模式下 body 就是文件本身,
    ///                  不能再去解 GitHubContentResponse wrapper
    /// 这里直接走 raw 模式(大小通吃),把 body 当 snapshot.json 直接 SyncCodec.decode。
    /// 注意 SHA 是另一码事——写端 422 retry 时 fetchCurrentSHA 用默认 JSON 模式取 SHA。
    func readSnapshot() async throws -> SyncSnapshot? {
        guard let url = contentsURL() else {
            throw SyncStorageError.notConfigured
        }

        // 第一步:取 raw 文件内容(raw 模式 body 就是文件本身,直接 SyncCodec.decode)
        var rawRequest = URLRequest(url: url)
        rawRequest.httpMethod = "GET"
        rawRequest.setValue("Bearer \(githubToken ?? "")", forHTTPHeaderField: "Authorization")
        rawRequest.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")

        let (rawData, rawResponse) = try await URLSession.shared.data(for: rawRequest)
        guard let rawHttp = rawResponse as? HTTPURLResponse else {
            throw SyncStorageError.unexpectedResponse
        }

        if rawHttp.statusCode == 404 {
            return nil  // 首次同步,云端没文件,正常
        }
        if rawHttp.statusCode == 401 {
            throw SyncStorageError.unauthorized
        }
        if rawHttp.statusCode >= 500 {
            throw SyncStorageError.serverError(status: rawHttp.statusCode)
        }
        guard (200..<300).contains(rawHttp.statusCode) else {
            let body = String(data: rawData, encoding: .utf8) ?? ""
            throw SyncStorageError.unexpectedStatus(rawHttp.statusCode, body: body)
        }

        // raw 模式下 body 就是 snapshot.json 本身,直接解
        do {
            return try SyncCodec.decode(rawData)
        } catch {
            AppLogger.error("SyncStorage: snapshot decode failed: \(error.localizedDescription)")
            throw SyncStorageError.fileCorrupted
        }
    }

    /// 写快照
    /// - 失败抛 SyncStorageError
    /// - 调用方应在后台 task 里调(不要在主线程同步等)
    func writeSnapshot(_ snapshot: SyncSnapshot) async throws {
        let data = try SyncCodec.encode(snapshot)
        try await performWrite(data: data)
    }

    /// 真正执行写操作(拿 SHA + PUT + 422 重试)
    private func performWrite(data: Data) async throws {
        guard let url = contentsURL() else {
            throw SyncStorageError.notConfigured
        }
        let b64 = data.base64EncodedString()
        // 不带 SHA(首次写);如果文件已存在,GitHub 会返回 422,然后自动重试
        try await putContents(url: url, contentB64: b64, sha: nil, message: "sync from \(deviceID)")
        AppLogger.info("SyncStorage: wrote snapshot (\(data.count) bytes) to \(repoPath ?? "?")")
    }

    /// PUT Contents API(支持 422 重试)
    private func putContents(url: URL, contentB64: String, sha: String?, message: String, isRetry: Bool = false) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(githubToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "message": message,
            "content": contentB64
        ]
        if let sha = sha {
            body["sha"] = sha
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncStorageError.unexpectedResponse
        }

        if http.statusCode == 401 {
            throw SyncStorageError.unauthorized
        }
        if http.statusCode == 422 && !isRetry {
            // 另一台设备同时写了 → 拿最新 SHA 重试
            AppLogger.info("SyncStorage: 422 sha_mismatch, refetching SHA and retrying")
            let latestSHA = try await fetchCurrentSHA()
            try await putContents(url: url, contentB64: contentB64, sha: latestSHA, message: message, isRetry: true)
            return
        }
        if http.statusCode >= 500 {
            throw SyncStorageError.serverError(status: http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncStorageError.unexpectedStatus(http.statusCode, body: body)
        }
    }

    /// 拿当前文件的 SHA(用于 422 重试)
    private func fetchCurrentSHA() async throws -> String {
        guard let url = contentsURL() else {
            throw SyncStorageError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(githubToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncStorageError.shaRefetchFailed
        }
        let ghResponse = try JSONDecoder().decode(GitHubContentResponse.self, from: data)
        return ghResponse.sha
    }

    /// 构造 Contents API URL
    private func contentsURL() -> URL? {
        guard let path = repoPath, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/contents/\(Self.snapshotFileName)")
    }

    /// 远端文件的"修改时间"(GitHub Contents API 不返回 mtime,返回 sha)
    /// - 这里返回 nil;UI 不会直接用,但保留接口以备将来
    func remoteFileModificationDate() -> Date? {
        return nil
    }
}

// MARK: - GitHub API 响应

struct GitHubContentResponse: Codable {
    let name: String
    let path: String
    let sha: String
    let size: Int
    let type: String
    let content: String
    let encoding: String
}

// MARK: - 错误

enum SyncStorageError: LocalizedError {
    case notConfigured
    case unauthorized
    case serverError(status: Int)
    case unexpectedStatus(Int, body: String = "")
    case unexpectedResponse
    case fileCorrupted
    case shaRefetchFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 GitHub token / repo"
        case .unauthorized: return "GitHub token 无效(401)。请重新生成 Personal Access Token 并更新设置"
        case .serverError(let status): return "GitHub 服务器错误 (\(status))"
        case .unexpectedStatus(let status, let body): return "GitHub 返回非预期状态 \(status): \(body.prefix(200))"
        case .unexpectedResponse: return "GitHub 返回了非 HTTP 响应"
        case .fileCorrupted: return "同步文件被破坏"
        case .shaRefetchFailed: return "拉取最新 SHA 失败,稍后重试"
        }
    }
}
