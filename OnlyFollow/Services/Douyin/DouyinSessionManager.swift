import Foundation

/// 抖音 Session 管理（单例）
///
/// 职责：
/// - 包装 DouyinSigner，向上层（API 服务）暴露"统一的 cookie + 签名"接口
/// - 缓存 msToken / webid / verify_fp（避免每次都从 WebView 拿）
/// - 检查 webid（firstSeen）是否新鲜，过期则从 WKWebView 的 RENDER_DATA 里抽
///
/// 使用模式：
/// - `await DouyinSessionManager.shared.initialize()` — app 启动后调一次
/// - `cookieString` — 拼好的 cookie 字符串，给 URLSession 用
/// - `signRequest(url:body:)` — 给 URL 拼上 X-Bogus / X-Gnarly
@MainActor
final class DouyinSessionManager {
    static let shared = DouyinSessionManager()

    private(set) var isInitialized = false

    private init() {}

    /// App 启动后调用一次：触发 WKWebView 加载抖音首页
    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true
        AppLogger.info("DouyinSessionManager: init")
        DouyinSigner.shared.ensureReady()
    }

    /// 拼好的 cookie header 值
    /// - 从 WKWebView 的 cookie store 读所有 cookie 后用 "; " 拼接
    /// - 同时合并 `AppSettings.douyinCookie`（用户扫码登录后保存的 cookie）
    /// - 用户 cookie 优先级高于 WKWebView 自动 cookie
    var cookieString: String {
        get async {
            let wkCookies = await DouyinSigner.shared.cookieString
            return Self.mergeCookies(prioritized: AppSettings.douyinCookie, base: wkCookies)
        }
    }

    /// 登录成功后被 `DouyinLoginService` 调用
    /// - 触发一个全局通知,让上层可以重置限流/冷启动状态
    static let loginSucceededNotification = Notification.Name("DouyinSessionManager.loginSucceeded")

    func notifyLoginSucceeded() {
        AppLogger.info("DouyinSessionManager: login succeeded, refreshing sign cache")
        // 重新触发一次 DouyinSigner 加载（新的 cookie 出现,首页 WKWebView 也需要刷新一遍）
        DouyinSigner.shared.refreshAfterLogin()
        NotificationCenter.default.post(name: Self.loginSucceededNotification, object: nil)
    }

    /// 合并两个 cookie 字符串
    /// - prioritized 里的同名 cookie 覆盖 base
    static func mergeCookies(prioritized: String, base: String) -> String {
        if prioritized.isEmpty { return base }
        if base.isEmpty { return prioritized }
        var merged: [String: String] = [:]
        for raw in base.split(separator: ";") {
            let parts = raw.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { merged[key] = val }
            }
        }
        for raw in prioritized.split(separator: ";") {
            let parts = raw.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { merged[key] = val }
            }
        }
        return merged
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 给 URL 加签名
    /// - 返回值是已经在 URL 后追加好 X-Bogus / X-Gnarly / msToken 的新 URL
    /// - 调用方不用关心签名细节
    func signRequest(url: String, body: String = "") async throws -> String {
        let sigs = try await DouyinSigner.shared.sign(url: url, body: body)
        // URL 已含 ? 则用 &,否则用 ?
        let suffix = sigs.queryStringSuffix()
        if suffix.isEmpty {
            return url
        }
        // 把 X-Bogus 等作为第一个参数插入,但 suffix 自己已经带 "&",所以直接拼
        return url + suffix
    }

    /// 仅返回签名结果（不含 URL 拼装），给 HTTP header 用的场景
    func signaturesFor(url: String, body: String = "") async throws -> DouyinRequestSignatures {
        try await DouyinSigner.shared.sign(url: url, body: body)
    }
}
