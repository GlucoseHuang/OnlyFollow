import Foundation
import WebKit

/// 抖音直播弹幕 webcast signature 专用签名器
///
/// 与 `DouyinSigner`（跑 `byted_acrawler`）的关键差异：
/// - 走的是**独立的隐藏 WKWebView**，加载 `about:blank`（干净上下文）
/// - 注入 `sign.js`（saermart/DouyinLiveWebFetcher 的 47KB 混淆副本）
/// - `sign.js` 头部的 `if (!window.byted_acrawler) { ... }` 守卫要求环境**没有** byted_acrawler
///   才能完成 crawler/get_sign 的定义，所以必须独立 WebView
/// - 用法: `let sig = try await DouyinWebcastSigner.shared.sign(md5Hex: "b1dc37b8...")`
///   返回 268~324 字符的 webcast signature（X-MS-STUB=md5hex 本身）
///
/// 调用方（`DouyinLiveSignature`）：
/// 1. 拼明文: `live_id=1,aid=6383,...,user_unique_id=...,identity=audience`
/// 2. MD5(明文) → 32 hex
/// 3. `sign(md5Hex: 32hex)` → signature
/// 4. WS URL 加 `&signature=...&X-MS-STUB=...`
@MainActor
final class DouyinWebcastSigner: NSObject {
    static let shared = DouyinWebcastSigner()

    /// 独立 WKWebView — 干净上下文, 没有 byted_acrawler, sign.js 能正常定义 crawler/get_sign
    private var webView: WKWebView?

    /// 是否就绪 (sign.js 注入完, get_sign 可调)
    private var isLoaded = false

    /// 就绪通知 (用于 waitForReady)
    static let readyNotification = Notification.Name("DouyinWebcastSigner.ready")

    /// 启动耗时 (用于打日志)
    private var loadStartedAt: Date?

    /// 注入失败次数 (用于诊断)
    private var injectFailures: Int = 0

    private override init() { super.init() }

    /// App 启动后调用: 加载 about:blank 并注入 sign.js
    /// - 不阻塞调用方
    /// - 与 DouyinSigner.ensureReady 平行调用, 两者互不依赖
    func ensureReady() {
        guard webView == nil else {
            // 已就绪或在加载中, 不重复
            return
        }
        AppLogger.info("DouyinWebcastSigner: 启动 WKWebView (about:blank) 注入 sign.js")
        loadStartedAt = Date()

        let userContent = WKUserContentController()

        // sign.js 必须在 document end 注入, 且不能与 byted_acrawler 冲突
        // (干净 WKWebView 默认就没有 byted_acrawler, 所以可以直接注)
        let signScript = WKUserScript(
            source: DouyinSignJS.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContent.addUserScript(signScript)

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        // 桌面 Chrome UA — sign.js 内部 navigator.userAgent 已写死, 这里设的 UA 主要是给将来 debug
        config.applicationNameForUserAgent = "Version/4.0 Chrome/120.0.0.0 Safari/537.36"

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = DouyinSigner.desktopUA
        wv.isHidden = true
        self.webView = wv

        // 加载空白页 — sign.js 在 atDocumentEnd 自动注入
        wv.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// 等待就绪
    /// - 已就绪直接返回
    /// - 未就绪: 如果还没启动, 触发; 如果在加载中, 等通知
    func waitForReady() async {
        if isLoaded { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var token: NSObjectProtocol!
            token = NotificationCenter.default.addObserver(
                forName: DouyinWebcastSigner.readyNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.resume()
                if let t = token { NotificationCenter.default.removeObserver(t) }
            }
            if self.webView == nil {
                self.ensureReady()
            }
        }
    }

    /// 算 webcast signature
    /// - `md5Hex`: MD5(明文) 的 32 字符 hex 字符串
    /// - 返回: 268~324 字符的 webcast signature
    /// - 失败抛错 (get_sign 不存在 / 返回空 / JS 异常)
    func sign(md5Hex: String) async throws -> String {
        if !isLoaded {
            await waitForReady()
        }
        guard let webView else {
            throw DouyinWebcastSignerError.notReady
        }

        // 安全转义 md5Hex (虽然只可能是 [0-9a-f], 防御一下)
        let safeMd5 = md5Hex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let js = """
        (function() {
            try {
                if (typeof get_sign !== 'function') {
                    return JSON.stringify({error: 'get_sign not defined'});
                }
                var sig = get_sign('\(safeMd5)');
                if (typeof sig !== 'string' || sig.length === 0) {
                    return JSON.stringify({error: 'get_sign returned empty', type: typeof sig});
                }
                return JSON.stringify({signature: sig, len: sig.length});
            } catch(e) {
                return JSON.stringify({error: String(e)});
            }
        })()
        """

        let result: Any? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: value)
            }
        }

        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DouyinWebcastSignerError.parseError("get_sign result not JSON: \(String(describing: result).prefix(200))")
        }
        if let err = obj["error"] as? String {
            throw DouyinWebcastSignerError.jsError(err)
        }
        guard let sig = obj["signature"] as? String, !sig.isEmpty else {
            throw DouyinWebcastSignerError.emptyResult
        }
        AppLogger.info("DouyinWebcastSigner: signature len=\(sig.count)")
        return sig
    }
}

// MARK: - WKNavigationDelegate

extension DouyinWebcastSigner: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // about:blank 加载完 → 探活 get_sign 是否已定义
        let probe = """
        (function() {
            return JSON.stringify({
                hasGetSign: typeof get_sign === 'function',
                hasCrawler: typeof crawler === 'function',
                navUA: (navigator && navigator.userAgent) || '',
                readyState: document.readyState
            });
        })()
        """
        webView.evaluateJavaScript(probe) { [weak self] result, error in
            guard let self else { return }
            if let error {
                AppLogger.error("DouyinWebcastSigner: 探活失败 \(error.localizedDescription)")
                self.injectFailures += 1
                // 失败也 mark ready, 避免永久 hang; 调用方会拿到 jsError
                self.isLoaded = true
                NotificationCenter.default.post(name: Self.readyNotification, object: nil)
                return
            }
            AppLogger.info("DouyinWebcastSigner: probe result = \(result ?? "nil")")
            // 不管探活结果如何, 都 mark ready
            // (如果 get_sign 没定义, 调用方会拿到 jsError, 重试机制可在调用方实现)
            self.isLoaded = true
            NotificationCenter.default.post(name: Self.readyNotification, object: nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLogger.error("DouyinWebcastSigner: about:blank 加载失败 \(error.localizedDescription)")
        isLoaded = true
        NotificationCenter.default.post(name: Self.readyNotification, object: nil)
    }
}

// MARK: - 错误

enum DouyinWebcastSignerError: LocalizedError {
    case notReady
    case parseError(String)
    case jsError(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .notReady: return "DouyinWebcastSigner 还没就绪"
        case .parseError(let m): return "DouyinWebcastSigner 解析失败: \(m)"
        case .jsError(let m): return "DouyinWebcastSigner JS 错误: \(m)"
        case .emptyResult: return "DouyinWebcastSigner get_sign 返回空"
        }
    }
}
