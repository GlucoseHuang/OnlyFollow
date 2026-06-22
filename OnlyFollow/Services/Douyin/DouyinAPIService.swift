import Foundation

/// 抖音 API 服务（actor 单例）
///
/// 关键设计：
/// - 每个请求都通过 DouyinSessionManager 拿最新的 cookie + 加签名
/// - 限流/风控由调用方（VideoSyncService / ContentView）控制，参考 B 站侧做法
/// - 不登录即可拿游客能拿的全部数据
/// - 已知差异：抖音 API 的 max_cursor 翻页无页码概念，靠 cursor 字段迭代
actor DouyinAPIService {
    static let shared = DouyinAPIService()

    private let session: URLSession
    private let webBaseURL = "https://www.douyin.com"
    /// 直播相关接口在 live.douyin.com 域名下(不是 www), 用错域名会 404
    private let liveBaseURL = "https://live.douyin.com"

    private var cache: [String: (data: Data, time: Date)] = [:]
    private let cacheTTL: TimeInterval = 300

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - User Info

    /// 获取抖音用户信息（通过 sec_uid）
    func fetchUserInfo(secUid: String) async throws -> DouyinUserInfo {
        let baseURL = "\(webBaseURL)/aweme/v1/web/user/profile/other/"
        let params = [
            "sec_user_id": secUid,
            "device_platform": "webapp",
            "aid": "6383",
            "pc_client_type": "1",
            "version_code": "190500",
            "version_name": "19.5.0",
            "cookie_enabled": "true",
            "platform": "PC"
        ]
        let url = try await buildSignedURL(base: baseURL, params: params)

        let data = try await fetchData(url: url, referer: "\(webBaseURL)/user/\(secUid)")
        // 调试：先打印完整 body 前 4000 字节
        let preview = String(data: data.prefix(4000), encoding: .utf8) ?? "<binary>"
        AppLogger.info("DouyinAPIService: fetchUserInfo body[0..4000]=\(preview)")
        // 针对性诊断: 解析 user dict 的 top-level keys + 找 live_room 字段
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let userDict = obj["user"] as? [String: Any] {
            let topKeys = userDict.keys.sorted().joined(separator: ",")
            let hasLiveRoom = userDict["live_room"] != nil
            let liveRoomInfo: String = {
                guard let lr = userDict["live_room"] as? [String: Any] else { return "missing" }
                if lr.isEmpty { return "empty({})" }
                let lrKeys = lr.keys.sorted().joined(separator: ",")
                return "present(keys=\(lrKeys), roomId=\(lr["room_id"] ?? "nil"), live_status=\(lr["live_status"] ?? "nil"), status=\(lr["status"] ?? "nil"))"
            }()
            AppLogger.info("DouyinAPIService: userDict诊断 topKeys=\(topKeys) hasLiveRoom=\(hasLiveRoom) live_room=\(liveRoomInfo)")
            // 如果 live_room 存在但非空,把每个字段都打出来(辅助判断解析是否漏)
            if let lr = userDict["live_room"] as? [String: Any], !lr.isEmpty {
                let lrDump = lr.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                AppLogger.info("DouyinAPIService: live_room完整字段: {\(lrDump)}")
            }
        }
        guard let resp = DouyinUserInfoResponse.from(data), let user = resp.user else {
            throw DouyinAPIError.parseError("用户信息解析失败")
        }
        // 额外把 live_room 字段的关键信息 dump 出来
        if let live = user.liveRoomInfo {
            AppLogger.info("DouyinAPIService: user \(user.nickname ?? "<nil>") has live_room: roomId=\(live.roomId ?? "nil") isLiving=\(live.isLiving ?? false) title=\(live.title ?? "nil")")
        } else {
            AppLogger.info("DouyinAPIService: user \(user.nickname ?? "<nil>") (secUid=\(secUid.prefix(8))...) — live_room 字段为空(未开播或 API 未返回)")
        }
        return user
    }

    // MARK: - User Videos

    /// 获取用户视频列表（首页或翻页）
    /// - maxCursor: 首次传 0；后续传上次响应的 max_cursor
    /// - count: 单页大小（抖音固定 20）
    func fetchUserVideos(secUid: String, maxCursor: Int = 0, count: Int = 40) async throws -> DouyinVideoListResponse {
        // count: 默认 50, 抖音单页理论支持更大但有反爬风险
        // - 测过 50/100 都能返回,但太大会触发风控
        // - 翻页靠 max_cursor,单页拉满 + 翻页比一次拉 100 稳
        let baseURL = "\(webBaseURL)/aweme/v1/web/aweme/post/"
        let params: [String: String] = [
            "sec_user_id": secUid,
            "max_cursor": "\(maxCursor)",
            "count": "\(count)",
            "device_platform": "webapp",
            "aid": "6383",
            "pc_client_type": "1",
            "version_code": "190500",
            "version_name": "19.5.0",
            "publish_video_strategy_type": "2",
            "screen_width": "1920",
            "screen_height": "1080",
            "cookie_enabled": "true"
        ]
        let url = try await buildSignedURL(base: baseURL, params: params)
        let data = try await fetchData(url: url, referer: "\(webBaseURL)/user/\(secUid)")
        // 针对性诊断: 找 video 数组首个 item 的 video.play_addr 结构
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = obj["aweme_list"] as? [[String: Any]], let first = list.first {
            let topKeys = first.keys.sorted().joined(separator: ",")
            let videoSub = first["video"] as? [String: Any] ?? [:]
            let videoKeys = videoSub.keys.sorted().joined(separator: ",")
            let playAddr = videoSub["play_addr"] as? [String: Any] ?? [:]
            let playAddrKeys = playAddr.keys.sorted().joined(separator: ",")
            let playAddrFirstURL = (playAddr["url_list"] as? [String])?.first
            let status_code = obj["status_code"] as? Int ?? -1
            let hasMore = obj["has_more"] as? Int ?? -1
            AppLogger.info("DouyinAPIService: awemeList诊断 count=\(count) returned=\(list.count) status_code=\(status_code) has_more=\(hasMore) awemeCount=\(obj["aweme_count"] as? Int ?? -1) max_cursor=\(obj["max_cursor"] as? Int ?? -1)")
            AppLogger.info("DouyinAPIService: firstItem topKeys=\(topKeys) videoKeys=\(videoKeys) playAddrKeys=\(playAddrKeys) firstPlayURL=\(playAddrFirstURL?.prefix(80) ?? "nil")")
        }
        guard let resp = DouyinVideoListResponse.from(data) else { throw DouyinAPIError.parseError("视频列表解析失败") }
        let list = resp.awemeList
        let firstPlayURL = list.first?.playURL?.prefix(80) ?? "nil"
        AppLogger.info("DouyinAPIService: videos secUid=\(secUid.prefix(8))... cursor=\(maxCursor) count=\(count) returned=\(list.count) hasMore=\(resp.hasMore) firstPlayURL=\(firstPlayURL)")
        return resp
    }

    // MARK: - Video Comments

    /// 获取单视频评论列表
    /// - cursor: 首次传 0；后续传上次响应的 cursor
    func fetchVideoComments(awemeId: String, cursor: Int = 0, count: Int = 20) async throws -> DouyinCommentListResponse {
        let baseURL = "\(webBaseURL)/aweme/v1/web/comment/list/"
        let params: [String: String] = [
            "aweme_id": awemeId,
            "cursor": "\(cursor)",
            "count": "\(count)",
            "device_platform": "webapp",
            "aid": "6383",
            "pc_client_type": "1",
            "version_code": "190500",
            "version_name": "19.5.0"
        ]
        let url = try await buildSignedURL(base: baseURL, params: params)
        let data = try await fetchData(url: url, referer: "\(webBaseURL)/video/\(awemeId)")
        guard let resp = DouyinCommentListResponse.from(data) else { throw DouyinAPIError.parseError("评论列表解析失败") }
        AppLogger.info("DouyinAPIService: comments for \(awemeId), cursor=\(cursor), returned=\(resp.comments.count), hasMore=\(resp.hasMore)")
        return resp
    }

    // MARK: - Live Room

    /// 获取直播间信息 + 拉流地址
    /// - webcastId: 可以是 webcast_id 也可以是 room_id（API 都接受）
    func fetchLiveRoom(webcastId: String, roomIdStr: String? = nil) async throws -> DouyinLiveRoomResponse {
        // ⚠️ 关键: 直播 enter 接口在 live.douyin.com 域名下,不是 www.douyin.com
        // 用错域名会返 404
        // 还要 web_rid + room_id_str 两个参数 (f2 的 UserLive 模型)
        let baseURL = "\(liveBaseURL)/webcast/room/web/enter/"
        let params: [String: String] = [
            "room_id": webcastId,
            "room_id_str": roomIdStr ?? webcastId,
            "web_rid": webcastId,
            "app_name": "douyin_web",
            "live_id": "1",
            "version_code": "180800",
            "webcast_sdk_version": "1.0.14",
            "aid": "6383",
            "device_platform": "web",
            "cookie_enabled": "true",
            "screen_width": "1920",
            "screen_height": "1080",
            "browser_language": "zh-CN",
            "browser_platform": "Win32",
            "browser_name": "Mozilla",
            "enter_source": "",
            "is_need_double_stream": "false",
            "insert_task_id": "",
            "live_reason": ""
        ]
        let url = try await buildSignedURL(base: baseURL, params: params)
        let data = try await fetchData(url: url, referer: "https://live.douyin.com/\(webcastId)")
        // 诊断: 直播 enter 接口 body 前 500 字节,辅助排查 404 / 风控
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
        AppLogger.info("DouyinAPIService: fetchLiveRoom roomId=\(webcastId) body[0..500]=\(preview)")
        guard let resp = DouyinLiveRoomResponse.from(data) else { throw DouyinAPIError.parseError("直播间解析失败") }
        AppLogger.info("DouyinAPIService: live room \(webcastId), status=\(resp.room?.status ?? 0), title=\(resp.room?.title ?? "")")
        return resp
    }

    /// 通过 sec_uid 查该用户当前是否开播；返回 (webcast_id, room_id) — 拿不到开播就返回 nil
    func fetchLiveRoomIdForUser(secUid: String) async throws -> (webcastId: String, roomId: String)? {
        // 抖音用户信息里的 live_room 不一定有 room_id（只有进入直播间 enter 接口才返回真实 room_id）
        // 但 live_room.room_id 字段通常就是 webcast_id，可以直接用
        let info = try await fetchUserInfo(secUid: secUid)
        guard let liveRoom = info.liveRoomInfo else {
            return nil
        }
        return (webcastId: liveRoom.roomId ?? "", roomId: liveRoom.roomId ?? "")
    }

    /// 独立检查用户是否开播（webcast/distribution/check_user_live_status/）
    /// - 这是 f2 用的官方端点,接受 sec_uid
    /// - 某些情况下 user_info 接口不返回 live_room(比如未登录 / 隐私设置),用这个备用
    /// - 返回: 如果在直播 → webcastId (room_id_str); 不在直播 → nil
    func fetchUserLiveStatus(secUid: String) async throws -> (webcastId: String, roomId: String)? {
        let baseURL = "https://live.douyin.com/webcast/distribution/check_user_live_status/"
        let params: [String: String] = [
            "sec_user_id": secUid,
            "aid": "6383",
            "app_name": "douyin_web",
            "version_code": "180800",
            "webcast_sdk_version": "1.0.14"
        ]
        let url = try await buildSignedURL(base: baseURL, params: params)
        let data = try await fetchData(url: url, referer: "https://live.douyin.com/")
        // 解析 response,形如 {"data":{"data":[{"user":{"sec_uid":"..."},"room_id_str":"...","status":2}]},"status_code":0}
        AppLogger.info("DouyinAPIService: fetchUserLiveStatus body[0..500]=\(String(data: data.prefix(500), encoding: .utf8) ?? "<binary>")")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let outerData = obj["data"] as? [String: Any] else { return nil }
        // 兼容 data 可能是 dict 或 array
        let list: [[String: Any]] = {
            if let arr = outerData["data"] as? [[String: Any]] { return arr }
            if let arr = outerData as? [[String: Any]] { return arr }
            return []
        }()
        // status == 2 表示直播中
        for item in list {
            let status = (item["status"] as? Int) ?? (item["status"] as? String).flatMap(Int.init) ?? 0
            if status == 2 {
                let roomId = item["room_id_str"] as? String ?? item["room_id"] as? String ?? ""
                let userDict = item["user"] as? [String: Any]
                let nick = userDict?["nickname"] as? String ?? ""
                AppLogger.info("DouyinAPIService: 找到正在直播, secUid=\(secUid.prefix(8))... roomId=\(roomId) nick=\(nick)")
                return (webcastId: roomId, roomId: roomId)
            }
        }
        AppLogger.info("DouyinAPIService: 用户未开播, secUid=\(secUid.prefix(8))...")
        return nil
    }

    // MARK: - Build signed URL

    /// 把基础 URL + params 拼好，通过 DouyinSessionManager 加 X-Bogus / X-Gnarly
    /// - 参数按 key 排序（抖音签名对参数顺序不敏感，但我们保持稳定）
    private func buildSignedURL(base: String, params: [String: String]) async throws -> URL {
        // 1. 拼 query
        let sortedKeys = params.keys.sorted()
        let queryPairs = sortedKeys.map { key -> String in
            let value = params[key] ?? ""
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        let queryString = queryPairs.joined(separator: "&")
        let urlWithoutSignature = "\(base)?\(queryString)"

        // 2. 加签名
        let signed = try await DouyinSessionManager.shared.signRequest(url: urlWithoutSignature)
        guard let url = URL(string: signed) else {
            throw DouyinAPIError.parseError("invalid signed URL: \(signed.prefix(200))")
        }
        return url
    }

    // MARK: - HTTP

    private func fetchData(url: URL, referer: String) async throws -> Data {
        let cacheKey = url.absoluteString
        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.time) < cacheTTL {
            return cached.data
        }

        var request = URLRequest(url: url)
        request.setValue(DouyinSigner.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        // 抖音 live 接口对压缩处理不一致,有时返回空 body。强制不要压缩,body 内容直接可读
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let cookie = await DouyinSessionManager.shared.cookieString
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            // 调试: 列出 cookie key(不暴露值),辅助确认 live.douyin.com 域名 cookie 是否齐全
            let cookieKeys = cookie.split(separator: ";").map { String($0).split(separator: "=").first.map(String.init) ?? "" }.joined(separator: ",")
            AppLogger.info("DouyinAPIService: Cookie keys=\(cookieKeys) (\(cookie.count) chars) -> \(url.host ?? "?")")
        } else {
            AppLogger.warning("DouyinAPIService: 无 cookie -> \(url.host ?? "?")")
        }

        AppLogger.info("DouyinAPIService: GET \(url.absoluteString.prefix(160))...")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DouyinAPIError.httpError(-1)
        }
        // 诊断: Content-Encoding / Content-Length / 实际 data 大小
        // 之前发现 live.douyin.com 接口偶发 body 为空, 怀疑是 chunked / gzip 行为
        let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding") ?? "(none)"
        let contentLength = http.value(forHTTPHeaderField: "Content-Length") ?? "(none)"
        AppLogger.info("DouyinAPIService: HTTP \(http.statusCode) Content-Encoding=\(contentEncoding) Content-Length=\(contentLength) data.count=\(data.count) (URL \(url.absoluteString.prefix(100)))")
        // 调试：即使是 200，也把 body 前 200 字符打印出来（首次调用）
        let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary \(data.count) bytes>"
        AppLogger.info("DouyinAPIService: HTTP \(http.statusCode) body[0..200]=\(bodyPreview)")

        if http.statusCode == 429 {
            throw DouyinAPIError.rateLimited
        }
        if http.statusCode == 403 || http.statusCode == 412 {
            throw DouyinAPIError.antiCrawler
        }
        guard http.statusCode == 200 else {
            AppLogger.error("DouyinAPIService: HTTP \(http.statusCode), body=\(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
            throw DouyinAPIError.httpError(http.statusCode)
        }

        cache[cacheKey] = (data, Date())
        return data
    }
}

// MARK: - Errors

enum DouyinAPIError: LocalizedError {
    case httpError(Int)
    case parseError(String)
    case notFound
    case rateLimited
    case antiCrawler

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "抖音网络错误 (\(code))"
        case .parseError(let msg): return "抖音数据解析失败: \(msg)"
        case .notFound: return "抖音未找到该用户/视频"
        case .rateLimited: return "抖音请求过于频繁，请稍后再试"
        case .antiCrawler: return "抖音风控触发，请稍后再试"
        }
    }
}
