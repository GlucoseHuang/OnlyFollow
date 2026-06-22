import Foundation

// MARK: - User Info
// 注：所有类型都用 JSONSerialization 手工解析（不走 Codable），
// 因为抖音 API 响应中嵌套字段太多，类型错误很容易导致整个解码失败。
// 用 [String: Any] 拿到的数据再"安全地"提取字段，能容忍任何字段缺失/类型错误。

/// 抖音用户信息（手工解析，最宽松的字段兼容）
struct DouyinUserInfo: Sendable {
    let nickname: String?
    let secUid: String?
    let uid: String?
    let signature: String?
    let avatarURL: String?
    let followerCount: Int?
    let followingCount: Int?
    let awemeCount: Int?
    let totalFavorited: Int?
    let liveRoomInfo: LiveRoomInfo?

    struct LiveRoomInfo: Sendable {
        let roomId: String?
        let title: String?
        let coverURL: String?
        let streamURL: String?
        /// 抖音同时返回 FLV + HLS 拉流地址,这两个字段分开暴露便于调用方按协议选流
        /// (macOS AVPlayer 原生不支持 FLV,HLS 优先)
        let flvURL: String?
        let hlsURL: String?
        let viewerCount: Int?
        /// 0 = 未直播, 2 = 直播中, 4 = 录像回放
        let liveStatus: Int?
        var isLiving: Bool {
            // 抖音 user API 的 live_status 实际值:
            // 0 = 未直播, 1 = 直播中, 2 = 直播中(老版), 4 = 录像回放
            // 只要非 0 都算"在播或刚播过"
            guard let s = liveStatus else { return false }
            return s == 1 || s == 2 || s == 4
        }

        /// 从 user 字典顶层字段构造 (2025 后抖音 API 直接把 live_status / room_id 放顶层,不再有 live_room 子对象)
        static func fromUserDict(_ userDict: [String: Any]) -> LiveRoomInfo? {
            // live_status 是数字(Int),0=未直播,2=直播中,4=回放
            // 历史版本也有过 live_room 子对象,做兜底
            let liveStatus: Int? = {
                if let n = userDict["live_status"] as? Int { return n }
                if let s = userDict["live_status"] as? String, let n = Int(s) { return n }
                if let lr = userDict["live_room"] as? [String: Any] {
                    if let n = lr["live_status"] as? Int { return n }
                    if let s = lr["live_status"] as? String, let n = Int(s) { return n }
                }
                return nil
            }()
            // room_id 也是顶层,可能 Int 也可能 String
            let roomId: String? = {
                if let s = userDict["room_id_str"] as? String, !s.isEmpty { return s }
                if let n = userDict["room_id"] as? Int { return String(n) }
                if let n = userDict["room_id"] as? Int64 { return String(n) }
                if let s = userDict["room_id"] as? String, !s.isEmpty { return s }
                if let lr = userDict["live_room"] as? [String: Any] {
                    if let s = lr["room_id"] as? String, !s.isEmpty { return s }
                }
                return nil
            }()
            // 不开播就返回 nil (上层会走兜底端点)
            // 直播状态值:
            //   0 = 未直播, 1 = 直播中, 2 = 直播中(老版字段), 4 = 录像回放
            // 非 0 都算"在播或刚播过"
            guard let s = liveStatus, s != 0 else { return nil }
            guard let roomId, !roomId.isEmpty else { return nil }
            // 兜底字段: 旧版有 live_room 子对象的话,从中拿 title/cover/stream_url
            let liveRoomSub = userDict["live_room"] as? [String: Any]
            let coverSub = liveRoomSub?["cover"] as? [String: Any]
            let streamSub = liveRoomSub?["stream_url"] as? [String: Any]

            // 2025+ 新版: room_data 是 JSON 字符串, 内含 status/user_count/stream_url
            // 验证: 实测 fetchUserInfo 返回 {"user":{"room_data":"{\"status\":2,\"user_count\":1434,\"stream_url\":{\"flv_pull_url\":{\"FULL_HD1\":\"...\"}}}..."}}
            // 绕过 webcast/room/web/enter 接口 (对部分房间返回 4001038 "该内容暂时无法查看")
            var flvURL: String? = nil
            var hlsURL: String? = nil
            var viewerCountFromRoomData: Int? = nil
            var statusFromRoomData: Int? = nil
            if let rdStr = userDict["room_data"] as? String,
               let data = rdStr.data(using: .utf8),
               let rd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                statusFromRoomData = rd["status"] as? Int
                viewerCountFromRoomData = rd["user_count"] as? Int
                if let stream = rd["stream_url"] as? [String: Any] {
                    // flv_pull_url 是个 dict, key 是清晰度 (FULL_HD1 / HD1 / SD1 / SD2)
                    if let flvDict = stream["flv_pull_url"] as? [String: String] {
                        // 优先最高画质
                        flvURL = flvDict["FULL_HD1"] ?? flvDict["HD1"] ?? flvDict["SD1"] ?? flvDict["SD2"] ?? flvDict.values.first
                    } else if let flvStr = stream["flv_pull_url"] as? String {
                        flvURL = flvStr
                    }
                    if let hlsStr = stream["hls_pull_url"] as? String {
                        hlsURL = hlsStr
                    }
                }
            }

            return LiveRoomInfo(
                roomId: roomId,
                title: liveRoomSub?["title"] as? String,
                coverURL: (coverSub?["url_list"] as? [String])?.first,
                // 优先用 room_data 里的 stream_url (新版 API), 兜底用 live_room 子对象
                streamURL: flvURL ?? hlsURL ?? (streamSub?["flv_pull_url"] as? String) ?? (streamSub?["hls_pull_url"] as? String),
                flvURL: flvURL ?? (streamSub?["flv_pull_url"] as? String),
                hlsURL: hlsURL ?? (streamSub?["hls_pull_url"] as? String),
                viewerCount: viewerCountFromRoomData,
                // room_data 的 status 更准确 (2=直播中), 优先用它
                liveStatus: statusFromRoomData ?? liveStatus
            )
        }
    }

    /// 从 JSON dict 安全解析（不抛错）
    static func from(_ dict: [String: Any]) -> DouyinUserInfo {
        // uid 可能是数字(Int)或字符串
        let uidStr: String?
        if let s = dict["uid"] as? String { uidStr = s }
        else if let n = dict["uid"] as? Int { uidStr = String(n) }
        else if let n = dict["uid"] as? Int64 { uidStr = String(n) }
        else if let s = dict["id"] as? String { uidStr = s }
        else { uidStr = nil }

        // avatar_thumb 在抖音实际是 {url_list: ["..."]} 对象，不是 string
        let avatar: String?
        if let s = dict["avatar_thumb"] as? String {
            avatar = s
        } else if let obj = dict["avatar_thumb"] as? [String: Any],
                  let urls = obj["url_list"] as? [String] {
            avatar = urls.first
        } else {
            avatar = nil
        }

        // follower_count 可能是 Int 或 String
        let follower: Int?
        if let n = dict["follower_count"] as? Int { follower = n }
        else if let s = dict["follower_count"] as? String { follower = Int(s) }
        else { follower = nil }

        let liveInfo = LiveRoomInfo.fromUserDict(dict)
        AppLogger.info("DouyinUserInfo: user=\(dict["nickname"] as? String ?? "<nil>") live_status=\((dict["live_status"] as? Int) ?? -1) room_id=\((dict["room_id_str"] as? String) ?? (dict["room_id"] as? Int).map(String.init) ?? "nil") liveInfo=\(liveInfo.map { "yes(roomId=\($0.roomId ?? "nil"))" } ?? "no")")
        return DouyinUserInfo(
            nickname: dict["nickname"] as? String,
            secUid: dict["sec_uid"] as? String,
            uid: uidStr,
            signature: dict["signature"] as? String,
            avatarURL: avatar,
            followerCount: follower,
            followingCount: (dict["following_count"] as? Int) ?? Int((dict["following_count"] as? String) ?? ""),
            awemeCount: (dict["aweme_count"] as? Int) ?? Int((dict["aweme_count"] as? String) ?? ""),
            totalFavorited: (dict["total_favorited"] as? Int) ?? Int((dict["total_favorited"] as? String) ?? ""),
            liveRoomInfo: liveInfo
        )
    }
}

/// 用户主页 API 响应包装
struct DouyinUserInfoResponse: Sendable {
    let user: DouyinUserInfo?
    let statusCode: Int?
    let statusMsg: String?

    /// 把原始 JSON 解析成 response
    static func from(_ data: Data) -> DouyinUserInfoResponse? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let user = (obj["user"] as? [String: Any]).map { DouyinUserInfo.from($0) }
        return DouyinUserInfoResponse(
            user: user,
            statusCode: obj["status_code"] as? Int,
            statusMsg: obj["status_msg"] as? String
        )
    }
}

// MARK: - Video List

struct DouyinVideoListResponse: Sendable {
    let awemeList: [DouyinVideoItem]
    let maxCursor: Int?
    let hasMore: Bool

    static func from(_ data: Data) -> DouyinVideoListResponse? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (obj["aweme_list"] as? [[String: Any]] ?? []).map { DouyinVideoItem.from($0) }
        return DouyinVideoListResponse(
            awemeList: list,
            maxCursor: obj["max_cursor"] as? Int,
            hasMore: obj["has_more"] as? Bool ?? false
        )
    }
}

struct DouyinVideoItem: Sendable {
    let awemeId: String?
    let desc: String?
    let createTime: Int?
    let duration: Int?
    let coverURL: String?
    let playURL: String?
    let viewCount: Int?
    let commentCount: Int?
    let likeCount: Int?
    let author: DouyinAuthor?

    struct DouyinAuthor: Sendable {
        let uid: String?
        let secUid: String?
        let nickname: String?
        let avatarURL: String?
    }

    /// 从 video.bit_rate 数组里挑最高画质 URL
    /// - bit_rate 数组里每个元素都有 {bit_rate: <bps>, gear_name: <...>, play_addr: {url_list: [...]}}
    /// - 默认 play_addr 是最低档(540p 左右),这里按 bit_rate 数字选最大
    /// - 如果 bit_rate 为空或解析失败,返回 nil,让 caller 退回默认 play_addr
    static func highestQualityPlayURL(from dict: [String: Any]) -> (url: String, gearName: String?, bitrate: Int)? {
        guard let videoSub = dict["video"] as? [String: Any] else { return nil }
        guard let bitRates = videoSub["bit_rate"] as? [[String: Any]], !bitRates.isEmpty else { return nil }
        // 选 bit_rate 数字最大的
        var best: (url: String, gearName: String?, bitrate: Int)?
        for entry in bitRates {
            let gear = entry["gear_name"] as? String
            let br: Int = (entry["bit_rate"] as? Int) ?? Int(entry["bit_rate"] as? String ?? "") ?? 0
            // 跳过有水印的档(play_addr vs play_addr_lowbr 等, 有 bitrate 2.x 倍说明有水印)
            // gear_name 规律: lowest_540_0 < lower_540_0 < normal_540_0 < normal_720_0 < higher_720_0 < normal_1080_0 < higher_1080_0
            // 但更可靠是按 bit_rate 数字排序
            guard let playAddr = entry["play_addr"] as? [String: Any],
                  let urls = playAddr["url_list"] as? [String],
                  let first = urls.first, !first.isEmpty else { continue }
            let currentBitrate = best?.bitrate ?? 0
            if best == nil || br > currentBitrate {
                best = (first, gear, br)
            }
        }
        return best
    }

    static func from(_ dict: [String: Any]) -> DouyinVideoItem {
        // 抖音响应结构: video.play_addr.url_list[0], video.cover.url_list[0], video.duration
        // 老代码错在读顶层 "play_url" / "cover",实际是嵌套在 video 子对象里
        let videoSub = dict["video"] as? [String: Any] ?? [:]

        // playURL: 优先 video.bit_rate 数组里最高画质, 退回 video.play_addr / video.play_url
        let playURL: String? = {
            // 1) 优先 bit_rate 数组里的最高画质(720p/1080p)
            if let best = Self.highestQualityPlayURL(from: dict) {
                return best.url
            }
            // 2) 退回 play_addr.url_list[0] (默认最低档)
            if let addr = videoSub["play_addr"] as? [String: Any],
               let urls = addr["url_list"] as? [String], let first = urls.first, !first.isEmpty {
                return first
            }
            if let pu = videoSub["play_url"] as? [String: Any],
               let urls = pu["url_list"] as? [String], let first = urls.first, !first.isEmpty {
                return first
            }
            if let s = dict["play_url"] as? String, !s.isEmpty { return s }
            if let obj = dict["play_url"] as? [String: Any],
               let urls = obj["url_list"] as? [String], let first = urls.first, !first.isEmpty {
                return first
            }
            return nil
        }()

        // cover: 同样优先 video.cover.url_list[0]
        let cover: String? = {
            if let c = videoSub["cover"] as? [String: Any],
               let urls = c["url_list"] as? [String], let first = urls.first, !first.isEmpty {
                return first
            }
            if let c = videoSub["dynamic_cover"] as? [String: Any],
               let urls = c["url_list"] as? [String], let first = urls.first, !first.isEmpty {
                return first
            }
            if let s = dict["cover"] as? String, !s.isEmpty { return s }
            if let obj = dict["cover"] as? [String: Any],
               let urls = obj["url_list"] as? [String], let first = urls.first, !first.isEmpty {
                return first
            }
            return nil
        }()

        // author
        let author: DouyinAuthor?
        if let a = dict["author"] as? [String: Any] {
            // avatar_thumb 同样是 url_list
            let avatar: String?
            if let s = a["avatar_thumb"] as? String { avatar = s }
            else if let obj = a["avatar_thumb"] as? [String: Any], let urls = obj["url_list"] as? [String] { avatar = urls.first }
            else { avatar = nil }

            // uid 可能是数字
            let uidStr: String?
            if let s = a["uid"] as? String { uidStr = s }
            else if let n = a["uid"] as? Int { uidStr = String(n) }
            else if let n = a["uid"] as? Int64 { uidStr = String(n) }
            else { uidStr = nil }

            author = DouyinAuthor(
                uid: uidStr,
                secUid: a["sec_uid"] as? String,
                nickname: a["nickname"] as? String,
                avatarURL: avatar
            )
        } else {
            author = nil
        }

        // duration: 优先 video.duration(毫秒),退回顶层 duration
        let durationMs: Int? = {
            if let n = videoSub["duration"] as? Int { return n }
            if let s = videoSub["duration"] as? String, let n = Int(s) { return n }
            if let n = dict["duration"] as? Int { return n }
            if let s = dict["duration"] as? String, let n = Int(s) { return n }
            return nil
        }()

        // 统计字段可能在 statistics 子对象里(aweme_list 接口),也可能在顶层(aweme/detail 接口)
        let stats = dict["statistics"] as? [String: Any] ?? [:]
        let playCount: Int? = {
            if let n = stats["play_count"] as? Int { return n }
            if let s = stats["play_count"] as? String, let n = Int(s) { return n }
            if let n = dict["play_count"] as? Int { return n }
            if let s = dict["play_count"] as? String, let n = Int(s) { return n }
            return nil
        }()
        let commentCount: Int? = {
            if let n = stats["comment_count"] as? Int { return n }
            if let s = stats["comment_count"] as? String, let n = Int(s) { return n }
            if let n = dict["comment_count"] as? Int { return n }
            if let s = dict["comment_count"] as? String, let n = Int(s) { return n }
            return nil
        }()
        let diggCount: Int? = {
            if let n = stats["digg_count"] as? Int { return n }
            if let s = stats["digg_count"] as? String, let n = Int(s) { return n }
            if let n = dict["digg_count"] as? Int { return n }
            if let s = dict["digg_count"] as? String, let n = Int(s) { return n }
            return nil
        }()

        // 一次性把首条视频的关键字段结构 dump 出来,辅助定位问题
        if !DouyinModelsDebug.dumpedOnce {
            DouyinModelsDebug.dumpedOnce = true
            let videoKeys = videoSub.keys.sorted().joined(separator: ",")
            let playAddrKeys = (videoSub["play_addr"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "nil"
            let playAddrFirst = (videoSub["play_addr"] as? [String: Any])?["url_list"] as? [String]
            // bit_rate 数组的每个 gear,供画质选择诊断
            let gears: String = (videoSub["bit_rate"] as? [[String: Any]] ?? []).map { e in
                let g = e["gear_name"] as? String ?? "?"
                let b = e["bit_rate"] as? Int ?? Int(e["bit_rate"] as? String ?? "") ?? 0
                let p = (e["play_addr"] as? [String: Any])?["url_list"] as? [String] ?? []
                let isW = (p.first ?? "").contains("playwm") ? "wm" : "ok"
                return "\(g)(\(b/1000)kbps,\(isW))"
            }.joined(separator: ",") ?? "nil"
            let chosenBest = Self.highestQualityPlayURL(from: dict)
            AppLogger.info("DouyinModels: 首条 aweme 结构, topKeys=\(dict.keys.sorted().joined(separator: ",")), videoKeys=\(videoKeys), playAddrKeys=\(playAddrKeys), playAddrFirst=\(playAddrFirst?.first?.prefix(60) ?? "nil"), bit_rate gears=\(gears), chosenBest=\(chosenBest.map { "\($0.gearName ?? "?")(\($0.bitrate/1000)kbps)" } ?? "nil"), coverURL=\(cover?.prefix(60) ?? "nil"), playURL=\(playURL?.prefix(60) ?? "nil")")
        }

        return DouyinVideoItem(
            awemeId: dict["aweme_id"] as? String,
            desc: dict["desc"] as? String,
            createTime: (dict["create_time"] as? Int) ?? Int((dict["create_time"] as? String) ?? ""),
            duration: durationMs,
            coverURL: cover,
            playURL: playURL,
            viewCount: playCount,
            commentCount: commentCount,
            likeCount: diggCount,
            author: author
        )
    }

    /// 转为项目内部 VideoItem
    func toVideoItem() -> VideoItem {
        let aidInt = Int(awemeId ?? "") ?? 0
        return VideoItem(
            id: awemeId ?? "",
            aid: aidInt,
            bvid: "",
            cid: 0,
            title: desc ?? "",
            coverURL: coverURL ?? "",
            // 去水印: 抖音 CDN 通过 btag 区分
            // - btag=30000 是无水印版本(默认画质)
            // - btag=80000e00038000 / 80000e00078000 等是有水印的
            // 两者都做,兼容新旧数据
            playURL: (playURL ?? "")
                .replacingOccurrences(of: "/playwm/", with: "/play/")
                // btag 替换(可能有水印): 8xxxx 模式 + cxxxx 模式(猜测) 都改 30000
                .replacingOccurrences(of: "btag=80000e00038000", with: "btag=30000")
                .replacingOccurrences(of: "btag=80000e00078000", with: "btag=30000")
                .replacingOccurrences(of: "btag=80000e00008000", with: "btag=30000")
                .replacingOccurrences(of: "btag=c0000e00038000", with: "btag=30000")
                .replacingOccurrences(of: "btag=c0000e00078000", with: "btag=30000")
                .replacingOccurrences(of: "btag=c0000e00008000", with: "btag=30000"),
            webURL: "https://www.douyin.com/video/\(awemeId ?? "")",
            duration: (duration ?? 0) / 1000,
            publishTime: Date(timeIntervalSince1970: TimeInterval(createTime ?? 0)),
            viewCount: viewCount ?? 0,
            danmakuCount: 0,
            commentCount: commentCount ?? 0,
            authorUID: author?.uid ?? "",
            authorName: author?.nickname ?? "",
            authorAvatar: author?.avatarURL ?? "",
            platform: "douyin",
            ugcSeasonID: nil,
            ugcSeasonTitle: nil
        )
    }
}

// MARK: - Comments

struct DouyinCommentListResponse: Sendable {
    let comments: [DouyinComment]
    let cursor: Int?
    let hasMore: Bool

    static func from(_ data: Data) -> DouyinCommentListResponse? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (obj["comments"] as? [[String: Any]] ?? []).map { DouyinComment.from($0) }
        return DouyinCommentListResponse(
            comments: list,
            cursor: obj["cursor"] as? Int,
            hasMore: obj["has_more"] as? Bool ?? false
        )
    }
}

struct DouyinComment: Identifiable, Sendable {
    let cid: String?
    let text: String?
    let createTime: Int?
    let diggCount: Int?
    let user: DouyinCommentUser?

    var id: String { cid ?? UUID().uuidString }

    struct DouyinCommentUser: Sendable {
        let uid: String?
        let nickname: String?
        let avatarURL: String?
    }

    static func from(_ dict: [String: Any]) -> DouyinComment {
        let userDict = dict["user"] as? [String: Any]
        let avatar: String?
        if let s = userDict?["avatar_thumb"] as? String { avatar = s }
        else if let obj = userDict?["avatar_thumb"] as? [String: Any],
                  let urls = obj["url_list"] as? [String] { avatar = urls.first }
        else { avatar = nil }

        let user = userDict.map {
            DouyinCommentUser(
                uid: ($0["uid"] as? String) ?? (($0["uid"] as? Int).map(String.init)) ?? (($0["uid"] as? Int64).map(String.init)),
                nickname: $0["nickname"] as? String,
                avatarURL: avatar
            )
        }
        return DouyinComment(
            cid: dict["cid"] as? String,
            text: dict["text"] as? String,
            createTime: (dict["create_time"] as? Int) ?? Int((dict["create_time"] as? String) ?? ""),
            diggCount: (dict["digg_count"] as? Int) ?? Int((dict["digg_count"] as? String) ?? ""),
            user: user
        )
    }
}

// MARK: - Live Room

struct DouyinLiveRoomResponse: Sendable {
    let room: DouyinLiveRoomData?
    let user: DouyinLiveRoomUser?

    struct DouyinLiveRoomData: Sendable {
        let id: String?
        let idStr: String?
        let title: String?
        let coverURL: String?
        let userCount: Int?
        let status: Int?
        let streamURL: DouyinStreamURL?
    }

    struct DouyinLiveRoomUser: Sendable {
        let id: String?
        let secUid: String?
        let nickname: String?
        let avatarURL: String?
    }

    static func from(_ data: Data) -> DouyinLiveRoomResponse? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let roomDict = obj["room"] as? [String: Any]
        let userDict = obj["user"] as? [String: Any]

        let room = roomDict.map { d -> DouyinLiveRoomData in
            let streamDict = d["stream_url"] as? [String: Any]
            let stream = streamDict.map {
                DouyinStreamURL(
                    flvPullURL: $0["flv_pull_url"] as? String,
                    hlsPullURL: $0["hls_pull_url"] as? String,
                    rtmpPullURL: $0["rtmp_pull_url"] as? String
                )
            }
            // cover 可能是 url_list 对象
            let cover: String?
            if let s = d["cover"] as? String { cover = s }
            else if let obj = d["cover"] as? [String: Any],
                      let urls = obj["url_list"] as? [String] { cover = urls.first }
            else { cover = nil }
            return DouyinLiveRoomData(
                id: d["id"] as? String ?? (d["id"] as? Int).map(String.init),
                idStr: d["id_str"] as? String,
                title: d["title"] as? String,
                coverURL: cover,
                userCount: (d["user_count"] as? Int) ?? Int((d["user_count"] as? String) ?? ""),
                status: d["status"] as? Int,
                streamURL: stream
            )
        }

        let user = userDict.map { d -> DouyinLiveRoomUser in
            let avatar: String?
            if let s = d["avatar_thumb"] as? String { avatar = s }
            else if let obj = d["avatar_thumb"] as? [String: Any],
                      let urls = obj["url_list"] as? [String] { avatar = urls.first }
            else { avatar = nil }
            return DouyinLiveRoomUser(
                id: (d["id"] as? String) ?? (d["id"] as? Int).map(String.init),
                secUid: d["sec_uid"] as? String,
                nickname: d["nickname"] as? String,
                avatarURL: avatar
            )
        }
        return DouyinLiveRoomResponse(room: room, user: user)
    }
}

struct DouyinStreamURL: Sendable {
    let flvPullURL: String?
    let hlsPullURL: String?
    let rtmpPullURL: String?
}


// MARK: - 调试辅助

/// 一次性 dump 控制,确保首条视频只 dump 一次,避免日志爆炸
enum DouyinModelsDebug {
    nonisolated(unsafe) static var dumpedOnce: Bool = false
}
