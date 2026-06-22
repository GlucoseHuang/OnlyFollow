import Foundation

/// B 站 API 服务（单例）
/// 关键设计：
/// - 单例：cache 和限流计数跨刷新共享，避免每次 refreshData 都从零开始
/// - 登录后冷却：QR 登录后 B 站对"刚扫码就刷接口"很敏感，加 5s 静默期
/// - 限流 3s + 指数退避：连续命中 -799 时每次 +2s 等待（最多 15s）
/// - WBI 失败不自动回退 plain：B 站对同一会话短时间内双倍请求才会触发 -799
/// - 命中限流时返回 stale cache（即使过期也行），避免用户看到空白
actor BilibiliAPIService {
    static let shared = BilibiliAPIService()

    private let session: URLSession
    private var lastRequestTime: Date = .distantPast
    private var cache: [String: (data: Data, time: Date)] = [:]
    private let cacheTTL: TimeInterval = 300
    private let staleTTL: TimeInterval = 1800
    private var consecutiveRateLimits: Int = 0
    private var postLoginCooldownUntil: Date = .distantPast

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// 标记一次新登录，让下一次请求等几秒
    func notifyJustLoggedIn() {
        postLoginCooldownUntil = Date().addingTimeInterval(5)
    }

    /// 命中限流时清掉计数（外部检测到恢复时调）
    func resetRateLimitCounter() {
        consecutiveRateLimits = 0
    }

    private func waitForRateLimit() async {
        let now = Date()

        // 1) 登录后静默期
        if now < postLoginCooldownUntil {
            let remaining = postLoginCooldownUntil.timeIntervalSince(now)
            AppLogger.info("B站API: 登录后冷却中，等待 \(Int(remaining * 1000))ms")
            try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
        }

        // 2) 基础限流 + 连续命中指数退避
        let baseDelay: TimeInterval = 3.0
        let backoff: TimeInterval = min(Double(consecutiveRateLimits) * 2.0, 15.0)
        let required = baseDelay + backoff
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < required {
            try? await Task.sleep(for: .milliseconds(Int((required - elapsed) * 1000)))
        }
        lastRequestTime = Date()
    }

    // MARK: - User Info

    func fetchUserInfo(mid: String) async throws -> BilibiliUserInfo {
        try await BilibiliSessionManager.shared.initialize()

        // WBI 优先（用户信息端点 WBI 一直 OK）
        do {
            return try await fetchUserInfoWBI(mid: mid)
        } catch APIError.rateLimited {
            throw APIError.rateLimited
        } catch APIError.antiCrawler {
            throw APIError.antiCrawler
        } catch {
            // 解析失败 / -403 / 其他：降级到 plain
            AppLogger.info("B站API: WBI用户不可用，降级到 plain: \(error.localizedDescription)")
            return try await fetchUserInfoPlain(mid: mid)
        }
    }

    private func fetchUserInfoWBI(mid: String) async throws -> BilibiliUserInfo {
        let params = BilibiliSessionManager.shared.signWBI(params: [
            "mid": mid,
            "dm_img_list": "[]",
            "dm_img_str": "V2ViR0wgMS",
            "dm_cover_img_str": "SW50ZWwoUikgSEQgR3JhcGhpY3NJbnRlbA"
        ])
        var components = URLComponents(string: "https://api.bilibili.com/x/space/wbi/acc/info")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        let data = try await bilibiliRequest(url: components.url!, referer: "https://space.bilibili.com/\(mid)")

        do {
            let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliUserInfo>.self, from: data)
            if wrapper.code == 0, let info = wrapper.data {
                AppLogger.info("WBI用户: mid=\(info.mid), name=\(info.name)")
                return info
            }
            AppLogger.error("B站API: WBI用户 code=\(wrapper.code) msg=\(wrapper.message ?? "nil") bodyLen=\(data.count)")
            let bodyStr = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            AppLogger.error("B站API: WBI用户 body=\(bodyStr)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let vv = dataObj["v_voucher"] as? String {
                AppLogger.error("B站API: WBI用户 v_voucher=\(vv) → 需要 captcha 验证")
            }
            if wrapper.code == -352 { throw APIError.antiCrawler }
            if wrapper.code == -799 { throw APIError.rateLimited }
            if wrapper.code == -403 { throw APIError.antiCrawler }
            throw APIError.parseError("WBI用户 code=\(wrapper.code)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            AppLogger.error("B站API: WBI用户 缺少字段 key=\(key.stringValue) path=\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) body=\(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
        } catch let DecodingError.typeMismatch(_, ctx) {
            AppLogger.error("B站API: WBI用户 类型不匹配 path=\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) desc=\(ctx.debugDescription)")
        } catch {
            AppLogger.error("B站API: WBI用户 解析失败 bodyLen=\(data.count) err=\(error.localizedDescription) head=\(String(data: data.prefix(200), encoding: .utf8) ?? "<binary>")")
        }
        throw APIError.parseError("WBI用户接口不可用")
    }

    // MARK: - User Videos

    func fetchUserVideos(mid: String, page: Int = 1, pageSize: Int = 30) async throws -> [VideoItem] {
        try await BilibiliSessionManager.shared.initialize()

        // 2026-06 更新：B站已对 plain /x/space/arc/search 加入风控（任何登录态都 -799）。
        // 现在 WBI 端点可用（修了 w_rid + 加上 bili_ticket），改为 WBI 优先
        do {
            return try await fetchUserVideosWBI(mid: mid, page: page, pageSize: pageSize)
        } catch {
            AppLogger.info("B站API: 视频 WBI 失败，尝试 plain: \(error.localizedDescription)")
            return try await fetchUserVideosPlain(mid: mid, page: page, pageSize: pageSize)
        }
    }

    /// 与 fetchUserVideos 类似，但额外返回分页元数据（总数 / 当前页 / 单页大小）
    /// 用于「全量历史拉取」的终止判定
    func fetchUserVideosWithPageInfo(mid: String, page: Int = 1, pageSize: Int = 30) async throws -> (videos: [VideoItem], pageInfo: BilibiliVideoListResponse.PageInfo) {
        try await BilibiliSessionManager.shared.initialize()

        // 同样 WBI 优先 + plain 兜底
        let data: Data
        let usedWBI: Bool
        do {
            let params = BilibiliSessionManager.shared.signWBI(params: [
                "mid": mid, "pn": "\(page)", "ps": "\(pageSize)", "order": "pubdate",
                "dm_img_list": "[]",
                "dm_img_str": "V2ViR0wgMS",
                "dm_cover_img_str": "SW50ZWwoUikgSEQgR3JhcGhpY3NJbnRlbA"
            ])
            var components = URLComponents(string: "https://api.bilibili.com/x/space/wbi/arc/search")!
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            data = try await bilibiliRequest(url: components.url!, referer: "https://space.bilibili.com/\(mid)")
            usedWBI = true
        } catch {
            AppLogger.info("B站API: 视频 WBI 失败，尝试 plain: \(error.localizedDescription)")
            let url = URL(string: "https://api.bilibili.com/x/space/arc/search?mid=\(mid)&pn=\(page)&ps=\(pageSize)&order=pubdate")!
            data = try await bilibiliRequest(url: url, referer: "https://space.bilibili.com/\(mid)")
            usedWBI = false
        }

        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliVideoListResponse>.self, from: data)
        if wrapper.code == -799 { throw APIError.rateLimited }
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -403 { throw APIError.antiCrawler }
        guard let listData = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no data") }
        let videos = listData.list.vlist.map { $0.toVideoItem(authorUID: mid) }
        guard let pageInfo = listData.page else {
            throw APIError.parseError("B站视频列表接口未返回 page 元数据")
        }
        AppLogger.info((usedWBI ? "WBI视频+page" : "Plain视频+page") + ": mid=\(mid), page=\(pageInfo.pn)/\(pageInfo.count), returned=\(videos.count)")
        return (videos, pageInfo)
    }

    private func fetchUserVideosWBI(mid: String, page: Int, pageSize: Int) async throws -> [VideoItem] {
        let params = BilibiliSessionManager.shared.signWBI(params: [
            "mid": mid, "pn": "\(page)", "ps": "\(pageSize)", "order": "pubdate",
            "dm_img_list": "[]",
            "dm_img_str": "V2ViR0wgMS",
            "dm_cover_img_str": "SW50ZWwoUikgSEQgR3JhcGhpY3NJbnRlbA"
        ])
        var components = URLComponents(string: "https://api.bilibili.com/x/space/wbi/arc/search")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        let data = try await bilibiliRequest(url: components.url!, referer: "https://space.bilibili.com/\(mid)")

        do {
            let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliVideoListResponse>.self, from: data)
            if wrapper.code == 0, let listData = wrapper.data {
                let videos = listData.list.vlist.map { $0.toVideoItem(authorUID: mid) }
                AppLogger.info("WBI视频: mid=\(mid), count=\(videos.count)")
                return videos
            }
            // 业务码错误
            AppLogger.error("B站API: WBI视频 code=\(wrapper.code) msg=\(wrapper.message ?? "nil") bodyLen=\(data.count)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let vv = dataObj["v_voucher"] as? String {
                AppLogger.error("B站API: WBI视频 v_voucher=\(vv) → 需要 captcha 验证")
            }
            if wrapper.code == -352 { throw APIError.antiCrawler }
            if wrapper.code == -799 { throw APIError.rateLimited }
            if wrapper.code == -403 { throw APIError.antiCrawler }
            throw APIError.parseError("WBI视频 code=\(wrapper.code)")
        } catch let DecodingError.dataCorrupted(ctx) {
            AppLogger.error("B站API: WBI视频 数据损坏: \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            AppLogger.error("B站API: WBI视频 缺少字段 key=\(key.stringValue) path=\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) body=\(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
        } catch let DecodingError.typeMismatch(_, ctx) {
            AppLogger.error("B站API: WBI视频 类型不匹配 path=\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) desc=\(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            AppLogger.error("B站API: WBI视频 字段为 null path=\(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            AppLogger.error("B站API: WBI视频 解析失败 bodyLen=\(data.count) err=\(error.localizedDescription) head=\(String(data: data.prefix(200), encoding: .utf8) ?? "<binary>")")
        }
        throw APIError.parseError("WBI视频接口不可用")
    }

    // MARK: - Plain endpoints (fallback)

    private func fetchUserInfoPlain(mid: String) async throws -> BilibiliUserInfo {
        let url = URL(string: "https://api.bilibili.com/x/space/acc/info?mid=\(mid)")!
        let data = try await bilibiliRequest(url: url, referer: "https://space.bilibili.com/\(mid)")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliUserInfo>.self, from: data)
        if wrapper.code == -799 { throw APIError.rateLimited }
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -403 { throw APIError.antiCrawler }
        guard let info = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no data") }
        AppLogger.info("Plain用户: mid=\(info.mid), name=\(info.name)")
        return info
    }

    private func fetchUserVideosPlain(mid: String, page: Int, pageSize: Int) async throws -> [VideoItem] {
        let url = URL(string: "https://api.bilibili.com/x/space/arc/search?mid=\(mid)&pn=\(page)&ps=\(pageSize)&order=pubdate")!
        let data = try await bilibiliRequest(url: url, referer: "https://space.bilibili.com/\(mid)")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliVideoListResponse>.self, from: data)
        if wrapper.code == -799 { throw APIError.rateLimited }
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -403 { throw APIError.antiCrawler }
        guard let listData = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no data") }
        let videos = listData.list.vlist.map { $0.toVideoItem(authorUID: mid) }
        AppLogger.info("Plain视频: mid=\(mid), count=\(videos.count)")
        return videos
    }


    // MARK: - UGC Season（合集）

    /// 拉取一个合集下的所有视频
    /// - 端点：/x/polymer/web-space/seasons_archives_list (官方推荐,需要 referer)
    /// - 需要 WBI 签名（参考 fetchUserVideosWBI）
    /// - 命中 -352 时上层应该降级到本地推荐（不要让用户体验卡住）
    /// - 返回：合集元信息 + 视频列表(已按 B 站默认顺序排好,通常是按发布时间升序)
    func fetchSeasonArchives(mid: String, seasonID: Int, pageNum: Int = 1, pageSize: Int = 30) async throws -> BilibiliSeasonArchivesResponse {
        try await BilibiliSessionManager.shared.initialize()
        let signed = BilibiliSessionManager.shared.signWBI(params: [
            "mid": mid,
            "season_id": String(seasonID),
            "page_num": String(pageNum),
            "page_size": String(pageSize),
            "sort_reverse": "false",
            "web_location": "333.999"
        ])
        var components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-space/seasons_archives_list")!
        components.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
        AppLogger.info("B站API: GET seasons_archives_list mid=\(mid) season_id=\(seasonID) page=\(pageNum)")
        let data = try await bilibiliRequest(url: components.url!, referer: "https://space.bilibili.com/\(mid)")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliSeasonArchivesResponse>.self, from: data)
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -799 { throw APIError.rateLimited }
        if wrapper.code == -404 { throw APIError.notFound }
        guard let resp = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no season data") }
        AppLogger.info("B站API: 合集 season_id=\(seasonID) 返回 \(resp.archives.count) 个视频 (total=\(resp.meta?.total ?? resp.archives.count))")
        return resp
    }

    // MARK: - Other APIs (less frequent, no WBI needed)

    /// 获取视频详情（raw, 含 pages[] / ugcSeason）
    /// - 端点: /x/web-interface/view?aid=XXX (普通 GET, 不需要 WBI)
    /// - 字段含义详见 SocialSisterYi/bilibili-API-collect docs/video/info.md
    /// - 调用方需要 .toVideoItem() 才能得到 VideoItem；保留 raw 是为了让上层能拿 pages[]（分P）
    func fetchVideoDetail(aid: String) async throws -> BilibiliVideoDetail {
        try await BilibiliSessionManager.shared.initialize()
        let url = URL(string: "https://api.bilibili.com/x/web-interface/view?aid=\(aid)")!
        let data = try await bilibiliRequest(url: url, referer: "https://www.bilibili.com")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliVideoDetail>.self, from: data)
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -799 { throw APIError.rateLimited }
        guard let detail = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no data") }
        // 把合集 ID + 分 P 数单独打一行, 便于快速判断
        AppLogger.info("B站API: 视频详情 aid=\(detail.aid) ugcSeasonID=\(detail.ugcSeasonID.map(String.init) ?? "nil(无合集)") pages=\(detail.pages?.count ?? 0)")
        return detail
    }

    func fetchLiveRoom(roomID: String) async throws -> LiveRoom {
        try await BilibiliSessionManager.shared.initialize()
        let url = URL(string: "https://api.bilibili.com/xlive/web-room/v1/index/getInfoByRoom?room_id=\(roomID)")!
        let data = try await bilibiliRequest(url: url, referer: "https://live.bilibili.com")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliLiveRoomResponse>.self, from: data)
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -799 { throw APIError.rateLimited }
        guard let roomData = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no data") }
        return roomData.toLiveRoom()
    }

    /// 获取直播弹幕 WebSocket 鉴权 token + host 列表
    /// 浏览器流程（参考 bilibili-live-chat）：
    /// 1. GET `room/v1/Room/room_init?id=xxx` 让服务端种 LIVE_BUVID
    /// 2. GET `xlive/web-room/v1/index/getDanmuInfo?id=xxx&type=0&web_location=444.8&wts&w_rid` 带 cookie + WBI 签名
    /// 2026 流程（lovelyyoshino）要求这个端点要 WBI 签名；浏览器可能因为在页面里拿了 __NEPTUNE_IS_MY_WAIFU__ 绕过，
    /// 但我们直接调 API 就老老实实按 WBI 签一下
    func fetchDanmuInfo(roomID: Int) async throws -> BilibiliDanmuInfo {
        try await BilibiliSessionManager.shared.initialize()
        // 1) 预热拿 LIVE_BUVID（live 子域的 cookie）
        let liveBuvid = (try? await fetchLiveRoomInit(roomID: roomID)) ?? ""
        // 2) WBI 签名 + 拿 token + host_list
        let signed = BilibiliSessionManager.shared.signWBI(params: [
            "id": String(roomID),
            "type": "0",
            "web_location": "444.8"
        ])
        var components = URLComponents(string: "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo")!
        components.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
        // 自己发请求（不走 bilibiliRequest）：要把 LIVE_BUVID 加进 Cookie
        let url = components.url!
        var request = URLRequest(url: url)
        request.setValue(BilibiliSessionManager.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        var cookies = BilibiliSessionManager.shared.cookieString
        if !liveBuvid.isEmpty, !cookies.lowercased().contains("live_buvid=") {
            cookies += cookies.isEmpty ? "LIVE_BUVID=\(liveBuvid)" : "; LIVE_BUVID=\(liveBuvid)"
        }
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        // 现代浏览器头
        request.setValue("\"Not_A Brand\";v=\"8\", \"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

        AppLogger.info("B站API: GET \(url.absoluteString) (WBI signed + LIVE_BUVID=\(liveBuvid.isEmpty ? "MISSING" : "ok"))")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = json["code"] as? Int ?? 0
            if code == -799 { throw APIError.rateLimited }
            if code == -352 || code == 65530 {
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
                AppLogger.error("B站API: getDanmuInfo -352 body=\(preview)")
                if let voucher = http.value(forHTTPHeaderField: "x-bili-gaia-vvoucher") {
                    AppLogger.error("B站API: getDanmuInfo -352 x-bili-gaia-vvoucher=\(voucher)")
                }
                throw APIError.antiCrawler
            }
        }
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliDanmuInfo>.self, from: data)
        guard let info = wrapper.data else { throw APIError.parseError(wrapper.message ?? "no data") }
        return info
    }

    /// 获取 B 站直播播放地址（HLS m3u8）
    /// 走 /xlive/web-room/v2/index/getRoomPlayInfo，按房间当前清晰度返回 HLS 流。
    /// AVPlayer 原生支持 HLS，FLV 不支持，所以这里只挑 http_hls 协议 + ts/fmp4 容器 + AVC 编码。
    /// - qn: 清晰度编号。0 = 服务端按该房间最高可用；10000=原画 / 400=蓝光 / 250=超清 / 150=高清 / 80=流畅
    /// - Returns: m3u8 URL + 实际清晰度编号
    /// 预热：先打 room/v1/Room/room_init 让服务端在 cookie 里种 LIVE_BUVID
    /// 浏览器在打 getDanmuInfo 之前会先访问 live.bilibili.com 的某个端点把 LIVE_BUVID 拿到，
    /// 否则 getDanmuInfo 会因为缺这个 live 子域的 cookie 而被风控（返回 -352）
    /// 参考：https://github.com/SocialSisterYi/bilibili-API-collect/issues/1433
    /// - Returns: 从 Set-Cookie 里解析出来的 LIVE_BUVID 值；解析不到就返回空串
    func fetchLiveRoomInit(roomID: Int) async throws -> String {
        try await BilibiliSessionManager.shared.initialize()
        var components = URLComponents(string: "https://api.live.bilibili.com/room/v1/Room/room_init")!
        components.queryItems = [URLQueryItem(name: "id", value: String(roomID))]
        // 自己发请求（不走 bilibiliRequest 公共层）：需要直接拿 Set-Cookie 头
        let url = components.url!
        var request = URLRequest(url: url)
        request.setValue(BilibiliSessionManager.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        let cookies = BilibiliSessionManager.shared.cookieString
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        AppLogger.info("B站API: GET \(url.absoluteString) (room_init 预热拿 LIVE_BUVID)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(-1)
        }
        // 从 Set-Cookie 头里抠 LIVE_BUVID
        // iOS URLSession 不会自动解析 Set-Cookie 到 http.cookies，要从 allHeaderFields 拿
        if let setCookieList = http.allHeaderFields["Set-Cookie"] as? String {
            for raw in setCookieList.components(separatedBy: ", ") {
                // Set-Cookie 可能被合并到一个字符串，要逐个检查
                if raw.contains("LIVE_BUVID=") {
                    if let value = raw.components(separatedBy: ";").first?
                        .replacingOccurrences(of: "LIVE_BUVID=", with: ""),
                       !value.isEmpty {
                        AppLogger.info("B站API: room_init 返回 LIVE_BUVID=\(value.prefix(16))...")
                        return value
                    }
                }
            }
        }
        AppLogger.info("B站API: room_init 未从 Set-Cookie 拿到 LIVE_BUVID, bodyLen=\(data.count)")
        return ""
    }

    func fetchLiveStreamURL(roomID: Int, qn: Int = 0) async throws -> (url: String, quality: Int) {
        try await BilibiliSessionManager.shared.initialize()
        // 关键参数：
        //   protocol=0,1 → http_stream, http_hls（只要 http_hls）
        //   format=0,1,2 → flv, ts, fmp4（AVPlayer 不支持 flv，只挑 ts/fmp4）
        //   codec=0,1    → AVC, HEVC（AVPlayer 不支持 HEVC，挑 AVC）
        //   platform=web + qn=0 = 走 web 端默认清晰度
        var components = URLComponents(string: "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo")!
        components.queryItems = [
            URLQueryItem(name: "room_id", value: "\(roomID)"),
            URLQueryItem(name: "protocol", value: "0,1"),
            URLQueryItem(name: "format", value: "0,1,2"),
            URLQueryItem(name: "codec", value: "0,1"),
            URLQueryItem(name: "qn", value: "\(qn)"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "ptype", value: "8"),
        ]
        let data = try await bilibiliRequest(url: components.url!, referer: "https://live.bilibili.com")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliLivePlayInfoResponse>.self, from: data)
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -799 { throw APIError.rateLimited }
        guard let playData = wrapper.data else {
            throw APIError.parseError(wrapper.message ?? "no play data")
        }
        // 房间未开播时 playurl_info.playurl 为 null
        guard let playurl = playData.playurlInfo?.playurl else {
            throw APIError.parseError("直播间未开播或 playurl_info 为空（roomID=\(roomID)）")
        }
        // 选第一条 HLS（http_hls）+ AVC 编码的流
        guard let hlsURL = playurl.firstHLSStreamURL() else {
            throw APIError.parseError("未找到 HLS 流（房间可能未开播）")
        }
        AppLogger.info("B站API: 直播流 roomID=\(roomID) qn=\(playData.playurlInfo?.currentQn ?? -1) url=\(hlsURL.prefix(120))...")
        return (hlsURL, playData.playurlInfo?.currentQn ?? qn)
    }

    /// 获取视频实际播放 URL（带 ?xxx 鉴权参数的 CDN 链接）
    /// fnval=1 让 server 返回 MP4/FLV（durl），避免 DASH 分离流，AVPlayer 才能直接播
    /// - Returns: (playURL, currentQuality)  视频直链 + 实际清晰度编号
    func fetchVideoPlayURL(aid: String, cid: Int) async throws -> (url: String, quality: Int) {
        try await BilibiliSessionManager.shared.initialize()
        // qn=64 默认 720P 高清；fnval=1 MP4/FLV；platform=html5
        let urlStr = "https://api.bilibili.com/x/player/playurl?avid=\(aid)&cid=\(cid)&qn=64&fnver=0&fnval=1&fourk=0&platform=html5&high_quality=1"
        let url = URL(string: urlStr)!
        let data = try await bilibiliRequest(url: url, referer: "https://www.bilibili.com")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliPlayURLData>.self, from: data)
        if wrapper.code == -352 { throw APIError.antiCrawler }
        if wrapper.code == -799 { throw APIError.rateLimited }
        guard let playData = wrapper.data else { throw APIError.parseError("no play data") }

        // 优先 durl（MP4/FLV 合并流），AVPlayer 能直接播
        if let durl = playData.durl.first, let urlStr = durl.url, !urlStr.isEmpty {
            return (urlStr, playData.quality)
        }
        // 没有合并流时，DASH 单视频流也不可用（需要 audio/video 合并，AVPlayer 不支持）
        throw APIError.parseError("无 MP4 合并流（清晰度 \(playData.quality) 可能仅提供 DASH）")
    }

    /// 获取视频弹幕 XML（直接 GET，无需 WBI）
    /// 返回的 XML 形如 <d p="time,type,fontsize,color,timestamp,pool,user_hash,id">content</d>
    func fetchVideoDanmaku(cid: Int) async throws -> String {
        try await BilibiliSessionManager.shared.initialize()
        let url = URL(string: "https://comment.bilibili.com/\(cid).xml")!
        var request = URLRequest(url: url)
        request.setValue(BilibiliSessionManager.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        let cookies = BilibiliSessionManager.shared.cookieString
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // B站返回的是 GBK 编码
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 评论（必须 WBI 签名，否则老接口 /x/v2/reply 会返回空 data）

    /// 获取视频评论区（第一页，按热度）
    /// 旧接口 /x/v2/reply 对大部分视频返回 `data.replies: null`（实际就是 B站下线了）；
    /// 新接口 /x/v2/reply/wbi/main 需要 w_rid 签名，否则 -352/-403。
    /// 参考 https://github.com/SocialSisterYi/bilibili-API-collect/blob/main/docs/comment/list.md
    /// - Parameters:
    ///   - aid: 视频 av 号
    ///   - mode: 0=按时间 1=按热度+时间 2=仅按时间 3=仅按热度
    ///   - paginationOffset: 第一次传 ""，之后用上次响应 `data.cursor.pagination_reply.next_offset`
    func fetchVideoComments(aid: String, mode: Int = 3, paginationOffset: String = "") async throws -> [BilibiliComment] {
        let result = try await fetchVideoCommentsWithCursor(aid: aid, offset: paginationOffset)
        return result.replies
    }

    /// 评论分页：返回 replies 列表 + 下一页游标
    /// 第一次 offset=""; 之后用上次返回的 nextOffset
    /// - WBI 优先；wbi/main 失败时降级到旧 /x/v2/reply
    func fetchVideoCommentsWithCursor(aid: String, offset: String = "") async throws -> (replies: [BilibiliComment], nextOffset: String) {
        try await BilibiliSessionManager.shared.initialize()
        do {
            return try await fetchVideoCommentsWBIMain(aid: aid, offset: offset)
        } catch APIError.commentAccessDenied {
            // wbi/main -403：降级到旧 /x/v2/reply（不带 WBI）
            AppLogger.info("B站API: 评论 wbi/main -403，降级到 /x/v2/reply")
            return try await fetchVideoCommentsLegacy(aid: aid, offset: offset)
        } catch {
            throw error
        }
    }

    private func fetchVideoCommentsWBIMain(aid: String, offset: String) async throws -> (replies: [BilibiliComment], nextOffset: String) {

        let baseParams: [String: String] = [
            "oid": aid,
            "type": "1",
            "mode": "3",                 // 3 = 仅按热度
            "pagination_str": "{\"offset\":\"\(offset)\"}",
            "plat": "1",
            "web_location": "1315875"
        ]
        let signed = BilibiliSessionManager.shared.signWBI(params: baseParams)
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/reply/wbi/main")!
        components.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }

        let data = try await bilibiliRequest(url: components.url!, referer: "https://www.bilibili.com")

        do {
            let wrapper = try JSONDecoder().decode(BilibiliResponse<BilibiliCommentResponse>.self, from: data)
            if wrapper.code != 0 {
                AppLogger.info("B站API: 评论 code=\(wrapper.code) msg=\(wrapper.message ?? "nil")")
                if wrapper.code == 12002 { throw APIError.parseError("评论区已关闭") }
                if wrapper.code == -352 { throw APIError.antiCrawler }
                if wrapper.code == -799 { throw APIError.rateLimited }
                if wrapper.code == -101 { throw APIError.parseError("未登录") }
                if wrapper.code == -403 {
                    AppLogger.error("B站API: 评论 -403 访问权限不足；可能 Cookie 失效、wbi 签名失败或视频评论区未开放")
                    throw APIError.commentAccessDenied
                }
                throw APIError.parseError("评论 code=\(wrapper.code)")
            }
            let replies = wrapper.data?.replies ?? []
            // 新版 cursor 在 data.cursor.pagination_reply.next_offset；缺字段时退到空串（表示到底）
            let nextOffset = wrapper.data?.cursor?.paginationReply?.nextOffset ?? ""
            return (replies, nextOffset)
        } catch let DecodingError.keyNotFound(key, ctx) {
            AppLogger.error("B站API: 评论 缺少字段 key=\(key.stringValue) path=\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) body=\(String(data: data.prefix(400), encoding: .utf8) ?? "<binary>")")
            throw APIError.parseError("评论字段缺失: \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, ctx) {
            AppLogger.error("B站API: 评论 类型不匹配 path=\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) desc=\(ctx.debugDescription)")
            throw APIError.parseError("评论类型不匹配")
        } catch {
            AppLogger.error("B站API: 评论 解析失败 err=\(error.localizedDescription) head=\(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
            throw error
        }
    }

    /// 降级方案：旧 /x/v2/reply 接口（无 WBI），用 pn 翻页
    /// 很多视频返回 code=0 但 data.replies=null（旧接口已逐步废弃），但偶尔还能拿到数据
    private func fetchVideoCommentsLegacy(aid: String, offset: String) async throws -> (replies: [BilibiliComment], nextOffset: String) {
        // offset 是字符串（B站 wbi/main cursor），旧接口是 pn 数字；粗略换算
        let pn = max(1, Int(offset) ?? 1)
        let url = URL(string: "https://api.bilibili.com/x/v2/reply?type=1&oid=\(aid)&pn=\(pn)&ps=20&sort=1")!
        let data = try await bilibiliRequest(url: url, referer: "https://www.bilibili.com")
        let wrapper = try JSONDecoder().decode(BilibiliResponse<LegacyCommentResponse>.self, from: data)
        if wrapper.code == 12002 { throw APIError.parseError("评论区已关闭") }
        if wrapper.code == -101 { throw APIError.parseError("未登录") }
        if wrapper.code == -403 { throw APIError.commentAccessDenied }
        if wrapper.code != 0 { throw APIError.parseError("评论 code=\(wrapper.code)") }
        let replies = wrapper.data?.replies ?? []
        // 旧接口没有 cursor；如果本页满 20 条就翻下一页
        let nextOffset = replies.count >= 20 ? String(pn + 1) : ""
        return (replies, nextOffset)
    }

    /// 旧 /x/v2/reply 响应：replies 平铺在 data 下（不再有 data.data 这一层）
    struct LegacyCommentResponse: Codable, Sendable {
        let replies: [BilibiliComment]?
    }

    // MARK: - Private

    private func bilibiliRequest(url: URL, referer: String) async throws -> Data {
        let cacheKey = url.absoluteString

        // 命中限流时优先用 stale cache（避免空白）
        if let cached = cache[cacheKey] {
            let age = Date().timeIntervalSince(cached.time)
            if age < cacheTTL {
                return cached.data
            }
            if age < staleTTL && consecutiveRateLimits > 0 {
                AppLogger.info("B站API: 限流中，使用 stale cache (age=\(Int(age))s)")
                return cached.data
            }
        }

        await waitForRateLimit()

        var request = URLRequest(url: url)
        request.setValue(BilibiliSessionManager.kDefaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        // Origin 必须与 Referer 同源，否则 B站会判定为跨域调用触发 -403
        if let origin = URL(string: referer) {
            request.setValue("\(origin.scheme ?? "https")://\(origin.host ?? "www.bilibili.com")", forHTTPHeaderField: "Origin")
        }
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        // 现代浏览器头：让服务端更难识别为脚本请求
        request.setValue("\"Not_A Brand\";v=\"8\", \"Chromium\";v=\"120\", \"Google Chrome\";v=\"120\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue("\"macOS\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        let cookies = BilibiliSessionManager.shared.cookieString
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        AppLogger.info("B站API: GET \(url.absoluteString.prefix(160))...")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.httpError(-1) }

        if httpResponse.statusCode == 412 {
            consecutiveRateLimits += 1
            AppLogger.error("B站API: HTTP 412 限流 (count=\(consecutiveRateLimits))")
            throw APIError.rateLimited
        }
        if httpResponse.statusCode == 403 {
            AppLogger.error("B站API: HTTP 403 风控")
            throw APIError.antiCrawler
        }
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        // 业务码（即使后续解码失败也先判定）
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = json["code"] as? Int ?? 0
            if code == -799 {
                consecutiveRateLimits += 1
                AppLogger.error("B站API: -799 限流 (count=\(consecutiveRateLimits))")
                throw APIError.rateLimited
            }
            if code == -352 {
                // -352 不再 markSessionExpired：B 站对刚登录的会话会瞬时返回 -352，
                // 实际是反爬挑战而非 token 失效，让上层重试
                // 打印响应体：v_voucher 文档说要从中读 voucher 字段确认触发的是 captcha 还是单纯风控
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
                AppLogger.error("B站API: -352 风控 body=\(preview)")
                // 也把响应头里的 x-bili-gaia-vvoucher 一并打出来
                if let voucher = httpResponse.value(forHTTPHeaderField: "x-bili-gaia-vvoucher") {
                    AppLogger.error("B站API: -352 x-bili-gaia-vvoucher=\(voucher)")
                }
                throw APIError.antiCrawler
            }
        }

        // 成功
        consecutiveRateLimits = 0
        cache[cacheKey] = (data, Date())
        return data
    }
}

struct BilibiliResponse<T: Codable>: Codable {
    let code: Int
    let message: String?
    let data: T?
}

enum APIError: LocalizedError {
    case httpError(Int)
    case parseError(String)
    case notFound
    case rateLimited
    case antiCrawler
    /// 评论接口的 -403：B 站拒绝返回评论（常见于未登录、Cookie 失效、w_rid 签名失败）
    case commentAccessDenied

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "网络错误 (\(code))"
        case .parseError(let msg): return "数据解析失败: \(msg)"
        case .notFound: return "未找到该用户"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .antiCrawler: return "B站风控触发，请稍后再试或重新扫码登录"
        case .commentAccessDenied: return "评论权限不足（可能是 Cookie 失效、wbi 签名未通过或视频评论区未开放）"
        }
    }
}

struct BilibiliPlayURLData: Codable, Sendable {
    let durl: [PlayURLItem]
    let dash: DashData?
    let quality: Int
    let acceptQuality: [Int]?
    struct PlayURLItem: Codable, Sendable { let url: String?; let size: Int64?; let length: Int64? }
    struct DashData: Codable, Sendable { let video: [DashVideoItem]; let audio: [DashAudioItem]? }
    struct DashVideoItem: Codable, Sendable {
        let baseURL: String?
        enum CodingKeys: String, CodingKey { case baseURL = "base_url" }
    }
    struct DashAudioItem: Codable, Sendable {
        let baseURL: String?
        enum CodingKeys: String, CodingKey { case baseURL = "base_url" }
    }
    enum CodingKeys: String, CodingKey { case durl, dash, quality, acceptQuality = "accept_quality" }
}
