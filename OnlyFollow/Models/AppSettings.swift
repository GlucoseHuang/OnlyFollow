import Foundation

/// App 全局设置，持久化到 UserDefaults
enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - B站 Cookie

    /// 用户从浏览器复制的完整 B站 cookie 字符串，或二维码登录保存的 cookie
    /// 包含 SESSDATA、bili_jct、DedeUserID 等
    static var bilibiliCookie: String {
        get { defaults.string(forKey: "bilibili_cookie") ?? "" }
        set { defaults.set(newValue, forKey: "bilibili_cookie") }
    }

    static var hasBilibiliCookie: Bool { !bilibiliCookie.isEmpty }

    /// 从 cookie 字符串中提取 bili_jct（B站 CSRF Token）
    static var bilibiliJct: String {
        for part in bilibiliCookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("bili_jct=") {
                return String(trimmed.dropFirst("bili_jct=".count))
            }
        }
        return ""
    }

    /// 上次验证登录的时间
    static var bilibiliLastVerifiedAt: Date {
        get { defaults.object(forKey: "bilibili_last_verified") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "bilibili_last_verified") }
    }

    /// 已登录用户的 uid
    static var bilibiliLoggedUID: Int {
        get { defaults.integer(forKey: "bilibili_logged_uid") }
        set { defaults.set(newValue, forKey: "bilibili_logged_uid") }
    }

    /// 已登录用户的昵称（展示用）
    static var bilibiliLoggedName: String {
        get { defaults.string(forKey: "bilibili_logged_name") ?? "" }
        set { defaults.set(newValue, forKey: "bilibili_logged_name") }
    }

    // MARK: - 「播完下一个」推荐

    /// 是否启用 B 站 UGC 合集自动连播（路径 1）
    /// - true：当前视频在合集中时, 播完自动跳到合集下一个
    /// - false：关闭, 不论合集是否存在, 都不连播
    static var seasonAutoplayEnabled: Bool {
        get { defaults.object(forKey: "rec.seasonAutoplay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "rec.seasonAutoplay") }
    }

    /// 本地推荐模式:路径 2 默认走哪个
    enum LocalRecommendMode: String, CaseIterable {
        case vector   // 本地向量(默认, 离线可用, 几乎免费)
        case deepseek // DeepSeek LLM(用户主动点才用; 不入默认连播链路)
    }

    /// 「合集自动补全」开关: 用户播放合集视频时, 是否自动触发单合集第一页的 backfill
    /// - 默认开(用户无感, 30s 内合集列表自动变长)
    /// - 关掉后只能手动点合集 sheet 顶部按钮 / 设置里的全量补全
    static var seasonAutoBackfillEnabled: Bool {
        get { defaults.object(forKey: "rec.seasonAutoBackfill") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "rec.seasonAutoBackfill") }
    }

    /// "AI 智能推荐"总开关（路径 2 整体）
    /// - 关掉后, 不论本地还是 DeepSeek, 都不在播完后弹推荐视频页
    /// - 合集逻辑（路径 1）独立于这个开关
    static var aiRecommendEnabled: Bool {
        get { defaults.object(forKey: "rec.aiEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "rec.aiEnabled") }
    }

    static var localRecommendMode: LocalRecommendMode {
        get { LocalRecommendMode(rawValue: defaults.string(forKey: "rec.localMode") ?? "") ?? .vector }
        set { defaults.set(newValue.rawValue, forKey: "rec.localMode") }
    }

    /// 推荐结果数量（播放结束后的封面网格行数）
    /// 范围 6-12, 默认 8
    static var recommendCount: Int {
        get {
            let v = defaults.integer(forKey: "rec.count")
            return (6...12).contains(v) ? v : 8
        }
        set { defaults.set(max(6, min(12, newValue)), forKey: "rec.count") }
    }

    // MARK: - Embedding (本地向量)

    /// 阿里云百炼 DashScope 兼容模式（默认）, 也可换 OpenAI / 其他兼容服务
    static var embeddingBaseURL: String {
        get { defaults.string(forKey: "emb.baseURL") ?? "https://dashscope.aliyuncs.com/compatible-mode/v1" }
        set { defaults.set(newValue, forKey: "emb.baseURL") }
    }

    static var embeddingAPIKey: String {
        get { defaults.string(forKey: "emb.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "emb.apiKey") }
    }

    static var hasEmbeddingAPIKey: Bool { !embeddingAPIKey.isEmpty }

    /// 模型名;目前固定 text-embedding-v4 1024 维
    static var embeddingModel: String {
        get { defaults.string(forKey: "emb.model") ?? "text-embedding-v4" }
        set { defaults.set(newValue, forKey: "emb.model") }
    }

    static var embeddingDimensions: Int {
        get { defaults.integer(forKey: "emb.dims") == 0 ? 1024 : defaults.integer(forKey: "emb.dims") }
        set { defaults.set(newValue, forKey: "emb.dims") }
    }

    // MARK: - DeepSeek (LLM 推荐备选)

    static var deepseekBaseURL: String {
        get { defaults.string(forKey: "ds.baseURL") ?? "https://api.deepseek.com/v1" }
        set { defaults.set(newValue, forKey: "ds.baseURL") }
    }

    static var deepseekAPIKey: String {
        get { defaults.string(forKey: "ds.apiKey") ?? "" }
        set { defaults.set(newValue, forKey: "ds.apiKey") }
    }

    static var hasDeepSeekAPIKey: Bool { !deepseekAPIKey.isEmpty }

    /// 默认 deepseek-v4-flash(便宜 + 速度快, 推荐任务够用)
    /// 用户在 Settings 改成 deepseek-v4-pro 也能用
    static var deepseekModel: String {
        get { defaults.string(forKey: "ds.model") ?? "deepseek-v4-flash" }
        set { defaults.set(newValue, forKey: "ds.model") }
    }

    // MARK: - 抖音 Cookie

    static var douyinCookie: String {
        get { defaults.string(forKey: "douyin_cookie") ?? "" }
        set { defaults.set(newValue, forKey: "douyin_cookie") }
    }

    static var hasDouyinCookie: Bool { !douyinCookie.isEmpty }

    // MARK: - 通用辅助

    /// 清空 B站登录态（保留 cookie 字段供用户排查，但清掉验证记录）
    static func clearBilibiliLoginRecord() {
        defaults.removeObject(forKey: "bilibili_last_verified")
        defaults.removeObject(forKey: "bilibili_logged_uid")
        defaults.removeObject(forKey: "bilibili_logged_name")
    }

    // MARK: - 弹幕密度

    /// 弹幕密度模式（用户可切换，对比性能）
    /// - off: 不显示弹幕
    /// - sparse: 用原版贪心算法, 每条轨道上一个 lifetime 窗口只放一条, 画面上更稀疏
    /// - dense: 用 canShoot 追击问题算法, 长弹幕走更快所以同轨可放更多, 画面更密集
    /// 切换时触发 DanmakuFloatingView / DanmakuLiveFloatingView 重新计算轨道
    enum DanmakuDensity: String, CaseIterable {
        case off, sparse, dense

        var label: String {
            switch self {
            case .off: return "关闭"
            case .sparse: return "稀疏"
            case .dense: return "密集"
            }
        }
    }

    /// 弹幕密度模式 (默认 dense, 与之前一致)
    static var danmakuDensity: DanmakuDensity {
        get {
            let raw = defaults.string(forKey: "danmaku_density") ?? DanmakuDensity.dense.rawValue
            return DanmakuDensity(rawValue: raw) ?? .dense
        }
        set {
            defaults.set(newValue.rawValue, forKey: "danmaku_density")
        }
    }

    /// 切换弹幕密度（off → sparse → dense → off 循环）
    /// - 单独的 `set` 不能 toggle，所以提供 cycle 方法
    static func cycleDanmakuDensity() -> DanmakuDensity {
        let all = DanmakuDensity.allCases
        let cur = danmakuDensity
        let next = all[(all.firstIndex(of: cur)! + 1) % all.count]
        danmakuDensity = next
        return next
    }
}
