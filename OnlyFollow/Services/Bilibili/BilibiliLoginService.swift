import Foundation
import CoreImage.CIFilterBuiltins
import UIKit

/// B 站二维码登录服务
/// 流程：generate → 展示二维码 → 轮询 poll → 扫码成功后从 Set-Cookie 提取 SESSDATA 等
actor BilibiliLoginService {
    static let shared = BilibiliLoginService()

    enum LoginStatus: Sendable {
        case waiting                  // 已生成，未扫码
        case scanned                  // 已扫码未确认
        case success(cookies: [String: String])  // 登录成功，返回的字典至少包含 SESSDATA
        case expired                  // 二维码过期
        case error(String)
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        // 隔离的 cookie 存储，不污染主请求
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// 生成二维码
    /// - Returns: (qrcodeKey 用于后续轮询, image 用于 UI 展示)
    func generate() async throws -> (qrcodeKey: String, image: UIImage) {
        let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!
        var req = URLRequest(url: url)
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        req.setValue(BilibiliSessionManager.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError(-1)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let code = json?["code"] as? Int, code == 0,
              let dict = json?["data"] as? [String: Any],
              let qrcodeKey = dict["qrcode_key"] as? String,
              let qrcodeURL = dict["url"] as? String else {
            throw APIError.parseError("生成二维码失败")
        }

        guard let image = makeQRCodeImage(from: qrcodeURL) else {
            throw APIError.parseError("二维码渲染失败")
        }
        AppLogger.info("BilibiliLogin: generated QR, key=\(qrcodeKey.prefix(8))...")
        return (qrcodeKey, image)
    }

    /// 轮询一次二维码状态
    /// - 86101 未扫码，86090 已扫码未确认，0 成功，86038 二维码失效
    func poll(qrcodeKey: String) async -> LoginStatus {
        let url = URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=\(qrcodeKey)")!
        var req = URLRequest(url: url)
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        req.setValue(BilibiliSessionManager.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .error("轮询接口非 200")
            }

            // 从响应头 Set-Cookie 提取所有 cookie
            let headerFields = http.allHeaderFields as? [String: String] ?? [:]
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            let cookieDict = Dictionary(cookies.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new })

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let code = json?["code"] as? Int, code == 0,
                  let dataObj = json?["data"] as? [String: Any] else {
                return .error("响应格式异常")
            }
            let innerCode = dataObj["code"] as? Int ?? -1
            let message = dataObj["message"] as? String ?? ""

            switch innerCode {
            case 86101:
                return .waiting
            case 86090:
                return .scanned
            case 0:
                AppLogger.info("BilibiliLogin: QR scan success, cookies=\(cookieDict.keys.sorted().joined(separator: ","))")
                return .success(cookies: cookieDict)
            case 86038:
                return .expired
            default:
                return .error("登录失败 (\(innerCode)) \(message)")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func makeQRCodeImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        guard let data = string.data(using: .utf8) else { return nil }
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
