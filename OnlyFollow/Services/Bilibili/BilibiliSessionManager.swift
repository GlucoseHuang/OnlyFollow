import Foundation
import CryptoKit

/// B 站登录状态
enum BilibiliLoginState: Equatable, Sendable {
    /// 从未验证过
    case unknown
    /// 没有 cookie 或验证失败
    case loggedOut
    /// 验证通过
    case loggedIn(uid: Int, name: String)
}

/// B 站会话管理（单例）
/// 负责管理 cookie、buvid、WBI 密钥；并提供登录态验证
final class BilibiliSessionManager: Sendable {
    static let shared = BilibiliSessionManager()

    /// 登录态变化通知（登录/登出/失效都发）
    static let loginStateDidChangeNotification = Notification.Name("BilibiliSessionManager.loginStateDidChange")

    private let lock = NSLock()
    private var _buvid3: String = ""
    private var _buvid4: String = ""
    private var _bNut: String = ""
    private var _biliTicket: String = ""
    private var _biliTicketExpiresAt: Date = .distantPast
    private var _imgKey: String = ""
    private var _subKey: String = ""
    private var _isInitialized = false
    private var _loginState: BilibiliLoginState = .unknown

    /// B站 WBI 接口对桌面浏览器 UA 通过率高，移动端 UA 会被风控拦截 -403/-352
    /// 参见 https://github.com/SocialSisterYi/bilibili-API-collect/blob/main/docs/misc/sign/wbi.md
    static let kDefaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let kDefaultReferer = "https://www.bilibili.com/"

    /// 当前登录态（线程安全读取）
    var loginState: BilibiliLoginState {
        lock.lock(); defer { lock.unlock() }
        return _loginState
    }

    /// 完整的 cookie 字符串（合并用户 cookie + 自动获取的 buvid）
    var cookieString: String {
        lock.lock()
        defer { lock.unlock() }

        let userCookie = AppSettings.bilibiliCookie

        // 自动添加的字段：仅在用户 cookie 里没有同名字段时才追加
        var autoParts: [String] = []
        let lowerUser = userCookie.lowercased()
        if !_buvid3.isEmpty, !lowerUser.contains("buvid3=") { autoParts.append("buvid3=\(_buvid3)") }
        if !_buvid4.isEmpty, !lowerUser.contains("buvid4=") { autoParts.append("buvid4=\(_buvid4)") }
        if !_bNut.isEmpty, !lowerUser.contains("b_nut=") { autoParts.append("b_nut=\(_bNut)") }
        if !_biliTicket.isEmpty, !lowerUser.contains("bili_ticket=") { autoParts.append("bili_ticket=\(_biliTicket)") }
        let autoCookie = autoParts.joined(separator: "; ")

        if userCookie.isEmpty {
            return autoCookie
        }
        if autoCookie.isEmpty {
            return userCookie
        }
        return "\(userCookie); \(autoCookie)"
    }

    func initialize() async throws {
        lock.lock()
        if _isInitialized {
            lock.unlock()
            return
        }
        lock.unlock()

        AppLogger.info("BilibiliSession: initializing...")

        // 先获取 bili_ticket（JWT 风控票据，3 天有效），它会顺带返回 WBI 密钥
        await fetchBiliTicket()

        // 如果用户已提供 cookie，直接用它获取 WBI 密钥（若 ticket 没回 key 才会走这里）
        if AppSettings.hasBilibiliCookie {
            AppLogger.info("BilibiliSession: using user-provided cookie")
            if !hasWBIKeys() {
                await fetchWBIKeys()
            }
            lock.lock()
            _isInitialized = true
            lock.unlock()
            AppLogger.info("BilibiliSession: ready (with user cookie)")
            return
        }

        // 否则自动获取 buvid
        await fetchBuvid()
        if !hasWBIKeys() {
            await fetchWBIKeys()
        }

        lock.lock()
        _isInitialized = true
        lock.unlock()
        AppLogger.info("BilibiliSession: ready (auto buvid)")
    }

    private func hasWBIKeys() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !_imgKey.isEmpty && !_subKey.isEmpty
    }

    /// 重置（用户更改 cookie 或登录/登出后调用）
    func reset() {
        lock.lock()
        _isInitialized = false
        _imgKey = ""
        _subKey = ""
        _biliTicket = ""
        _biliTicketExpiresAt = .distantPast
        _loginState = .unknown
        lock.unlock()
    }

    // MARK: - 登录态

    /// 验证当前 cookie 是否仍然有效
    /// 命中 /x/web-interface/nav，data.isLogin 为 true 即视为已登录
    /// 距离上次成功验证不足 5 分钟时直接复用结果（避免冷启动时反复打 nav）
    func verifyLogin(force: Bool = false) async -> BilibiliLoginState {
        let cached = loginState
        if !force, case .loggedIn = cached,
           Date().timeIntervalSince(AppSettings.bilibiliLastVerifiedAt) < 300 {
            return cached
        }

        // 没有 cookie 直接判定为登出
        if !AppSettings.hasBilibiliCookie {
            updateLoginState(.loggedOut, persist: false)
            return .loggedOut
        }

        do {
            try await initialize()
            let url = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
            var req = URLRequest(url: url)
            req.setValue(Self.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
            req.setValue(cookieString, forHTTPHeaderField: "Cookie")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                updateLoginState(.loggedOut, persist: false)
                return .loggedOut
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["code"] as? Int == 0,
                  let dataObj = json["data"] as? [String: Any],
                  let isLogin = dataObj["isLogin"] as? Bool else {
                updateLoginState(.loggedOut, persist: false)
                return .loggedOut
            }
            if isLogin {
                let uid = dataObj["mid"] as? Int ?? 0
                let name = dataObj["uname"] as? String ?? ""
                let state: BilibiliLoginState = .loggedIn(uid: uid, name: name)
                updateLoginState(state, persist: true)
                AppLogger.info("BilibiliSession: login verified, uid=\(uid), name=\(name)")
                return state
            } else {
                updateLoginState(.loggedOut, persist: true)
                AppLogger.info("BilibiliSession: cookie present but isLogin=false")
                return .loggedOut
            }
        } catch {
            AppLogger.error("BilibiliSession: verifyLogin failed: \(error.localizedDescription)")
            return loginState
        }
    }

    /// 二维码登录成功后保存 cookies
    /// 合并到已有 cookie（已有 SESSDATA 则覆盖）
    func saveLoginCookies(_ cookies: [String: String]) {
        let cookieString = cookies
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")

        // 合并：如果 AppSettings 已有 cookie，保留 SESSDATA 等被新 cookie 覆盖
        let existing = AppSettings.bilibiliCookie
        var merged: [String: String] = [:]
        for pair in existing.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                merged[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        for (k, v) in cookies { merged[k] = v }
        let final = merged
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")

        AppSettings.bilibiliCookie = final
        AppLogger.info("BilibiliSession: saved login cookies, fields=\(merged.keys.sorted().joined(separator: ","))")
        reset()
        // 触发重新初始化 + 验证 + 通知 API 服务进入登录后冷却期
        Task {
            try? await initialize()
            _ = await verifyLogin(force: true)
            await BilibiliAPIService.shared.notifyJustLoggedIn()
        }
    }

    /// 用户主动登出
    func logout() {
        AppSettings.bilibiliCookie = ""
        AppSettings.clearBilibiliLoginRecord()
        reset()
        updateLoginState(.loggedOut, persist: false)
        AppLogger.info("BilibiliSession: logged out")
    }

    /// 标记当前 cookie 已失效（被风控/412/-352 时调用）
    func markSessionExpired() {
        guard case .loggedIn = loginState else { return }
        AppLogger.info("BilibiliSession: marking session expired")
        AppSettings.clearBilibiliLoginRecord()
        updateLoginState(.loggedOut, persist: false)
    }

    private func updateLoginState(_ newState: BilibiliLoginState, persist: Bool) {
        lock.lock()
        let old = _loginState
        _loginState = newState
        lock.unlock()
        if persist, case .loggedIn(let uid, let name) = newState {
            AppSettings.bilibiliLoggedUID = uid
            AppSettings.bilibiliLoggedName = name
            AppSettings.bilibiliLastVerifiedAt = Date()
        }
        if old != newState {
            // 切回主线程后再发通知，避免 SwiftUI 视图订阅者在后台线程更新 @State
            let notification = Notification(name: Self.loginStateDidChangeNotification, object: newState)
            if Thread.isMainThread {
                NotificationCenter.default.post(notification)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(notification)
                }
            }
        }
    }

    // MARK: - 获取 bili_ticket（JWT 风控票据，3 天有效）

    /// 获取 bili_ticket。票据在 B站 Web 端用于风控判定，缺失会触发 -403。
    /// 该接口顺带返回当日的 WBI img_key / sub_key，可用于替代 /nav 拉取。
    /// 文档: https://github.com/SocialSisterYi/bilibili-API-collect/blob/main/docs/misc/sign/bili_ticket.md
    private func fetchBiliTicket() async {
        // 已有且未过期（提前 1 天刷新，留余量）
        lock.lock()
        let cached = _biliTicket
        let expiresAt = _biliTicketExpiresAt
        lock.unlock()
        if !cached.isEmpty && expiresAt > Date().addingTimeInterval(86400) {
            return
        }

        let ts = Int(Date().timeIntervalSince1970)
        let hexsign = Self.hmacSHA256Hex(key: "XgwSnGZ1p", message: "ts\(ts)")

        var components = URLComponents(string: "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket")!
        components.queryItems = [
            URLQueryItem(name: "key_id", value: "ec02"),
            URLQueryItem(name: "hexsign", value: hexsign),
            URLQueryItem(name: "context[ts]", value: "\(ts)"),
            URLQueryItem(name: "csrf", value: AppSettings.bilibiliJct)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(Self.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.kDefaultReferer, forHTTPHeaderField: "Referer")
        // 带 cookie 才能拿到与登录态绑定的 ticket
        let cookies = AppSettings.bilibiliCookie
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                AppLogger.error("BilibiliSession: fetchBiliTicket HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["code"] as? Int == 0,
                  let dataObj = json["data"] as? [String: Any] else {
                AppLogger.error("BilibiliSession: fetchBiliTicket invalid response, bodyLen=\(data.count)")
                return
            }

            var ticket = ""
            var wbiImg = ""
            var wbiSub = ""
            var createdAt: Int = 0
            var ttl: Int = 0
            if let t = dataObj["ticket"] as? String, !t.isEmpty { ticket = t }
            if let nav = dataObj["nav"] as? [String: Any] {
                if let img = nav["img"] as? String {
                    wbiImg = Self.extractWBIKey(from: img)
                }
                if let sub = nav["sub"] as? String {
                    wbiSub = Self.extractWBIKey(from: sub)
                }
            }
            if let c = dataObj["created_at"] as? Int { createdAt = c }
            if let t = dataObj["ttl"] as? Int { ttl = t }

            lock.lock()
            if !ticket.isEmpty {
                _biliTicket = ticket
                _biliTicketExpiresAt = Date().addingTimeInterval(TimeInterval(ttl > 0 ? ttl : 259200))
            }
            if !wbiImg.isEmpty { _imgKey = wbiImg }
            if !wbiSub.isEmpty { _subKey = wbiSub }
            lock.unlock()

            if !ticket.isEmpty {
                AppLogger.info("BilibiliSession: bili_ticket ok (createdAt=\(createdAt), ttl=\(ttl)s), wbiImg=\(wbiImg.prefix(8))... wbiSub=\(wbiSub.prefix(8))...")
            }
        } catch {
            AppLogger.error("BilibiliSession: fetchBiliTicket failed: \(error.localizedDescription)")
        }
    }

    /// 从 `https://i0.hdslb.com/bfs/wbi/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.png` 抽取 32 位 key
    private static func extractWBIKey(from url: String) -> String {
        guard let lastSlash = url.split(separator: "/").last,
              let dotIndex = lastSlash.firstIndex(of: ".") else {
            return ""
        }
        return String(lastSlash[..<dotIndex])
    }

    /// HMAC-SHA256 十六进制输出。`XgwSnGZ1p` 是 B站公开的 ticket 签名密钥。
    private static func hmacSHA256Hex(key: String, message: String) -> String {
        let keyData = Data(key.utf8)
        let messageData = Data(message.utf8)
        let hmac = HMAC<SHA256>.authenticationCode(for: messageData, using: SymmetricKey(data: keyData))
        return Data(hmac).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 获取 buvid

    private func fetchBuvid() async {
        let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!
        var request = URLRequest(url: url)
        request.setValue(Self.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.kDefaultReferer, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               let headerFields = httpResponse.allHeaderFields as? [String: String] {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                for cookie in cookies {
                    lock.lock()
                    if cookie.name == "buvid3" && _buvid3.isEmpty { _buvid3 = cookie.value }
                    if cookie.name == "buvid4" && _buvid4.isEmpty { _buvid4 = cookie.value }
                    if cookie.name == "b_nut" && _bNut.isEmpty { _bNut = cookie.value }
                    lock.unlock()
                }
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any] {
                lock.lock()
                if let b3 = dataObj["b_3"] as? String, !b3.isEmpty { _buvid3 = b3 }
                if let b4 = dataObj["b_4"] as? String, !b4.isEmpty { _buvid4 = b4 }
                lock.unlock()
            }
            AppLogger.info("BilibiliSession: buvid3=\(_buvid3.prefix(10))...")
        } catch {
            AppLogger.error("BilibiliSession: fetchBuvid failed: \(error.localizedDescription)")
        }

        if _buvid3.isEmpty {
            await fetchBuvidFromHomepage()
        }
    }

    private func fetchBuvidFromHomepage() async {
        let url = URL(string: "https://www.bilibili.com")!
        var request = URLRequest(url: url)
        request.setValue(Self.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               let headerFields = httpResponse.allHeaderFields as? [String: String] {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                for cookie in cookies {
                    lock.lock()
                    if cookie.name == "buvid3" && _buvid3.isEmpty { _buvid3 = cookie.value }
                    if cookie.name == "buvid4" && _buvid4.isEmpty { _buvid4 = cookie.value }
                    if cookie.name == "b_nut" && _bNut.isEmpty { _bNut = cookie.value }
                    lock.unlock()
                }
            }
        } catch { }
    }

    // MARK: - 获取 WBI 密钥

    private func fetchWBIKeys() async {
        let url = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
        var request = URLRequest(url: url)
        request.setValue(Self.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.kDefaultReferer, forHTTPHeaderField: "Referer")

        lock.lock()
        var currentCookie: String
        if !AppSettings.bilibiliCookie.isEmpty {
            currentCookie = AppSettings.bilibiliCookie
        } else {
            var parts: [String] = []
            if !_buvid3.isEmpty { parts.append("buvid3=\(_buvid3)") }
            if !_buvid4.isEmpty { parts.append("buvid4=\(_buvid4)") }
            if !_bNut.isEmpty { parts.append("b_nut=\(_bNut)") }
            currentCookie = parts.joined(separator: "; ")
        }
        lock.unlock()

        if !currentCookie.isEmpty {
            request.setValue(currentCookie, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let wbiImg = dataObj["wbi_img"] as? [String: String] {
                let imgUrl = wbiImg["img_url"] ?? ""
                let subUrl = wbiImg["sub_url"] ?? ""
                let imgKey = imgUrl.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? ""
                let subKey = subUrl.split(separator: "/").last?.split(separator: ".").first.map(String.init) ?? ""
                if !imgKey.isEmpty {
                    lock.lock()
                    _imgKey = imgKey
                    _subKey = subKey
                    lock.unlock()
                    AppLogger.info("BilibiliSession: WBI keys: img=\(imgKey.prefix(8))..., sub=\(subKey.prefix(8))...")
                    return
                }
            }
            AppLogger.info("BilibiliSession: nav response parse failed, using hardcoded keys")
        } catch {
            AppLogger.error("BilibiliSession: fetchWBIKeys failed: \(error.localizedDescription)")
        }

        lock.lock()
        _imgKey = "7cd084941338484aae1ad9425b84077c"
        _subKey = "4932caff0ff746eab6f01bf08b70ac45"
        lock.unlock()
    }

    // MARK: - WBI 签名

    func signWBI(params: [String: String]) -> [String: String] {
        lock.lock()
        let img = _imgKey
        let sub = _subKey
        lock.unlock()

        let mixinKeyEncTab: [Int] = [
            46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,
            33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,
            61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52
        ]

        let orig = img + sub
        let chars = Array(orig)
        let mixed = mixinKeyEncTab.map { String(chars[$0]) }.joined()
        let mixinKey = String(mixed.prefix(32))

        // 关键：必须按键名升序排序后才能计算 w_rid，否则 server 端校验失败返回 -403
        // 不能用 Dictionary 暂存（Swift Dictionary 无序），必须保留 sorted 后的数组顺序
        var sorted = params.map { (key: $0.key, value: $0.value) }
        sorted.sort { $0.key < $1.key }
        let wts = Int(Date().timeIntervalSince1970)
        sorted.append((key: "wts", value: "\(wts)"))

        // 过滤 value 中的 "!'()*" 字符（参考 B站官方 WBI 签名规则）
        let filtered = sorted.map { (key: $0.key, value: $0.value.filter { !"!'()*".contains($0) }) }

        // B站 WBI 签名要求：先 sort，然后对每对 key=value 做 percent-encode
        // 字符集比 urlencode 更严格一些（去掉 +&=;[]），与 Python urllib.parse.urlencode 一致
        // 不做编码会导致 w_rid 与 server 端算出的不一致（最常见 -403 原因之一）
        let charset = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "+&=;[]"))
        let query = filtered.map { pair -> String in
            let k = pair.key.addingPercentEncoding(withAllowedCharacters: charset) ?? pair.key
            let v = pair.value.addingPercentEncoding(withAllowedCharacters: charset) ?? pair.value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        let inputData = Data((query + mixinKey).utf8)
        let digest = Insecure.MD5.hash(data: inputData)
        let wRid = digest.map { String(format: "%02x", $0) }.joined()

        // 调试：打印排序后的 query（用于验证 -403 是否由 w_rid 计算错误导致）
        AppLogger.info("WBI sign: query=\(query.prefix(220))")
        AppLogger.info("WBI sign: mixin=\(mixinKey) w_rid=\(wRid)")

        var signedParams = params
        signedParams["wts"] = "\(wts)"
        signedParams["w_rid"] = wRid
        return signedParams
    }
}
