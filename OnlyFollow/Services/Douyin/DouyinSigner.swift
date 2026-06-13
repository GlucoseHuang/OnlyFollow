import Foundation
import WebKit

/// 通过隐藏 WKWebView 调用抖音网页端 JS 签名函数
/// 优势：抖音更新 JS 后自动适配，无需硬编码签名算法
@MainActor
final class DouyinSigner: NSObject {
    private var webView: WKWebView?
    private var isReady = false
    private var pendingResolvers: [CheckedContinuation<DouyinSignatures, Error>] = []

    func ensureReady() async throws {
        guard !isReady else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setupWebView { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func sign(url: String, userAgent: String) async throws -> DouyinSignatures {
        guard isReady, let webView else {
            throw SignerError.notReady
        }
        return try await withCheckedThrowingContinuation { continuation in
            let js = """
            (function() {
                try {
                    var url = '\(url)';
                    var userAgent = '\(userAgent)';
                    // 调用抖音网页端签名函数
                    if (typeof window._bytedAcrawler !== 'undefined' && typeof window._bytedAcrawler.sign === 'function') {
                        var sign = window._bytedAcrawler.sign({url: url});
                        return JSON.stringify({xBogus: sign.XBogus || '', msToken: window.msToken || ''});
                    }
                    return JSON.stringify({xBogus: '', msToken: window.msToken || ''});
                } catch(e) {
                    return JSON.stringify({error: e.message});
                }
            })()
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    continuation.resume(throwing: SignerError.parseError)
                    return
                }
                if let errMsg = obj["error"] {
                    continuation.resume(throwing: SignerError.jsError(errMsg))
                    return
                }
                let sig = DouyinSignatures(
                    xBogus: obj["xBogus"] ?? "",
                    msToken: obj["msToken"] ?? ""
                )
                continuation.resume(returning: sig)
            }
        }
    }

    var cookies: String {
        // 从 WKWebView cookie store 读取
        get async {
            guard let webView else { return "" }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let cookies = await store.allCookies()
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    private func setupWebView(completion: @escaping (Result<Void, Error>) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        // 加载抖音首页以获取 JS 签名函数和 msToken
        guard let url = URL(string: "https://www.douyin.com") else {
            completion(.failure(SignerError.invalidURL))
            return
        }
        wv.load(URLRequest(url: url))
    }

    enum SignerError: Error {
        case notReady
        case parseError
        case jsError(String)
        case invalidURL
        case loadTimeout
    }
}

extension DouyinSigner: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        // 通知所有等待的请求
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isReady = false
    }
}
