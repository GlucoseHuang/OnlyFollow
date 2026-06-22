import Foundation
import WebKit
import UIKit

/// 抖音扫码登录服务（基于 WKWebView）
///
/// 为什么不用 URLSession（不像 B 站那样）：
/// - `sso.douyin.com/get_qrcode/` 现在返回的是 React SPA 的 HTML 页面，必须在浏览器里跑 JS 才能生成二维码
/// - 抖音开放平台的 OAuth 扫码需要注册 client_key/client_secret
/// - 主流开源项目（f2、TikTokDownloader）的结论：抖音扫码登录已不再支持 URLSession 流程
///
/// 因此这里用一个新的、可见的 WKWebView 加载抖音的扫码登录页（与现有 `DouyinSigner` 的隐藏 WebView 分开），
/// 让抖音自己的 JS 渲染二维码 → 用户在抖音 App 扫码 → 抖音把 WebView 重定向回 `www.douyin.com` 并 Set-Cookie sessionid。
/// 我们再从 cookie store 读出 cookie 存到 `AppSettings.douyinCookie`。
///
/// 关键差异（vs 现有 DouyinSigner）：
/// - DouyinSigner 用的是 hidden WebView，加载 douyin.com 拿 ttwid/odin_tt/msToken/签名
/// - 本服务用的是 visible WebView，加载 sso.douyin.com 完成登录
/// - 两者都共享 `WebsiteDataStore.default()`，所以 cookie 会自动合并
@MainActor
final class DouyinLoginService: NSObject {
    static let shared = DouyinLoginService()

    /// 登录状态（与 BilibiliLoginService.LoginStatus 对齐，方便上层复用 UI 思路）
    enum LoginStatus: Sendable {
        case idle
        case loading          // 正在加载登录页
        case showingQR        // 已展示二维码，等用户扫码
        case scanned          // 已扫码未确认
        case success          // 登录成功
        case expired          // 二维码过期
        case error(String)
    }

    /// 登录完成后的回调（在主线程触发）。cookies 是从 WKWebView 抽出的字典
    /// - 关键字段：`sessionid`、`sessionid_ss`、`uid_tt`、`sid_tt` 等
    var onStatusChange: ((LoginStatus) -> Void)?

    private var webView: WKWebView?
    private var urlObserver: NSKeyValueObservation?
    private var hasDetectedSuccess = false

    private override init() {
        super.init()
    }

    // MARK: - 公开 API

    /// 创建并启动扫码登录 WebView
    /// - 重复调用会先销毁旧的 WebView
    /// - 必须在主线程调用
    func start(onView: @escaping (WKWebView) -> Void) {
        // 清理旧实例
        stop()

        let config = WKWebViewConfiguration()
        // 共享 cookie store，确保 login cookie 跟 DouyinSigner 的 hidden WebView 互通
        config.websiteDataStore = .default()
        // 用桌面 Chrome UA，跟现有 DouyinSigner 一致
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = DouyinSigner.desktopUA
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.bounces = false
        self.webView = wv
        self.hasDetectedSuccess = false

        // 观察 URL 变化：登录成功时 WebView 会从 sso.douyin.com 重定向到 www.douyin.com
        urlObserver = wv.observe(\.url, options: [.new, .initial]) { [weak self] _, _ in
            guard let self, let url = wv.url else { return }
            Task { @MainActor in
                self.handleURLChange(url)
            }
        }

        // 加载抖音 SSO 扫码登录页
        onStatusChange?(.loading)
        let loginURL = URL(string: "https://sso.douyin.com/get_qrcode/?service=https%3A%2F%2Fwww.douyin.com%2F&need_back_url=true&size=180&aid=6383&language=zh")!
        wv.load(URLRequest(url: loginURL))

        // 把 WebView 返回给调用方（一般是 sheet 容器）
        onView(wv)
    }

    /// 销毁 WebView
    func stop() {
        urlObserver?.invalidate()
        urlObserver = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    // MARK: - URL 变化处理

    /// 根据 URL 变化推断登录状态
    /// - 仍在 sso.douyin.com → 还在扫码中
    /// - 跳到 www.douyin.com 或 douyin.com 根 → 登录成功，Set-Cookie 已下发
    private func handleURLChange(_ url: URL) {
        guard !hasDetectedSuccess else { return }
        let host = url.host ?? ""
        let path = url.path

        // 1. 跳到 www.douyin.com 或 iesdouyin.com → 登录成功
        if host.contains("www.douyin.com") || host.contains("iesdouyin.com") {
            // 等一下让 Set-Cookie 落到 cookie store 再去取
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                await self.detectLoginSuccess()
            }
            return
        }

        // 2. 仍在 sso.douyin.com → 还需展示二维码
        if host.contains("sso.douyin.com") {
            // 如果 URL 包含 token 之类参数且 path 是 /check_qrcode/，说明是轮询路径（用户已扫码后页面轮询）
            if path.contains("check") || url.absoluteString.contains("check_qrcode") {
                onStatusChange?(.scanned)
            } else {
                onStatusChange?(.showingQR)
            }
            return
        }

        // 3. 其它（如登录失败跳转）
        AppLogger.info("DouyinLogin: 跳转至非常规 URL: \(url.absoluteString.prefix(160))")
    }

    /// 从 cookie store 取 cookie，判断是否登录成功
    private func detectLoginSuccess() async {
        let store = webView?.configuration.websiteDataStore.httpCookieStore
        let allCookies = (await store?.allCookies()) ?? []
        let cookieDict = Dictionary(allCookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new })

        // 关键 cookie: sessionid / sessionid_ss / uid_tt
        // 抖音登录态 cookie 通常是 sessionid（普通）和 sessionid_ss（Secure）
        let hasSessionid = (cookieDict["sessionid"]?.isEmpty == false) || (cookieDict["sessionid_ss"]?.isEmpty == false)
        let hasUid = (cookieDict["uid_tt"]?.isEmpty == false)

        if hasSessionid || hasUid {
            hasDetectedSuccess = true
            AppLogger.info("DouyinLogin: 登录成功，sessionid=\(cookieDict["sessionid"]?.prefix(8) ?? "nil") sessionid_ss=\(cookieDict["sessionid_ss"]?.prefix(8) ?? "nil") uid_tt=\(cookieDict["uid_tt"] ?? "nil"), 共 \(cookieDict.count) 个 cookie")

            // 保存到 AppSettings
            let cookieString = cookieDict
                .filter { !$0.value.isEmpty }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")
            AppSettings.douyinCookie = cookieString
            DouyinSessionManager.shared.notifyLoginSucceeded()

            onStatusChange?(.success)
        } else {
            AppLogger.warning("DouyinLogin: 跳转完成但未发现 session cookie, host=\(webView?.url?.host ?? "?") cookies=\(cookieDict.keys.sorted().joined(separator: ","))")
            // 某些场景下会跳到 douyin.com 首页但 cookie 还没落，再等一次
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !self.hasDetectedSuccess {
                    await self.detectLoginSuccess()
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension DouyinLoginService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // 用 evaluateJavaScript 探一下页面 title，方便判断状态
            webView.evaluateJavaScript("document.title") { result, _ in
                if let title = result as? String {
                    AppLogger.info("DouyinLogin: page loaded, title=\(title.prefix(60))")
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLogger.error("DouyinLogin: navigation failed: \(error.localizedDescription)")
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 阻止跳到非 douyin.com 的外部链接（防止在 WebView 里跳走）
        if let host = navigationAction.request.url?.host {
            let isDouyin = host.contains("douyin.com") || host.contains("bytedance.com") || host.contains("snssdk.com")
            if !isDouyin {
                AppLogger.info("DouyinLogin: 阻止跳转到外部 URL: \(host)")
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}

// MARK: - 错误类型

enum DouyinLoginError: LocalizedError {
    case noWebView
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noWebView: return "登录 WebView 尚未启动"
        case .noCookies: return "登录响应未包含 session cookie"
        }
    }
}
