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
        /// 抖音专属: 每个画质对应的 HLS m3u8 URL。
        /// key 是 sdk_key (ld/sd/hd/uhd/origin), value 是 m3u8 完整 URL。
        /// 画质选择 UI 用这个。只填该房间实际可用的画质(空 HLS 不填)。
        var hlsURLsByQuality: [String: String] = [:]
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
            var hlsURLsByQuality: [String: String] = [:]
            var viewerCountFromRoomData: Int? = nil
            var statusFromRoomData: Int? = nil
            if let rdStr = userDict["room_data"] as? String,
               let data = rdStr.data(using: .utf8),
               let rd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                statusFromRoomData = rd["status"] as? Int
                viewerCountFromRoomData = rd["user_count"] as? Int

                // 实际数据(2026-06 抖音 web 端真实协议):
                // stream_url 下同时有 flv_pull_url (dict, 4 个画质) 和 live_core_sdk_data.pull_data.stream_data
                // stream_data 是个 JSON string, 内含 data["<quality>"].main.hls (m3u8) / main.flv
                // hls 字段是真正的 HLS URL,AVPlayer 原生支持,这是首选
                // flv 字段给的是 FLV,macOS 不支持,作为兜底
                if let stream = rd["stream_url"] as? [String: Any] {
                    // 1) flv_pull_url: 顶层 dict, key 是 FULL_HD1/HD1/SD1/SD2 (按画质选择)
                    if let flvDict = stream["flv_pull_url"] as? [String: String] {
                        flvURL = flvDict["FULL_HD1"] ?? flvDict["HD1"] ?? flvDict["SD1"] ?? flvDict["SD2"] ?? flvDict.values.first
                    } else if let flvStr = stream["flv_pull_url"] as? String {
                        flvURL = flvStr
                    }

                    // 2) 顶层 hls_pull_url 兼容 (老接口历史遗留)
                    if let hlsStr = stream["hls_pull_url"] as? String, !hlsStr.isEmpty {
                        hlsURL = hlsStr
                    } else if let hlsDict = stream["hls_pull_url"] as? [String: String] {
                        hlsURL = hlsDict["FULL_HD1"] ?? hlsDict["HD1"] ?? hlsDict["SD1"] ?? hlsDict["SD2"] ?? hlsDict.values.first
                    }

                    // 3) live_core_sdk_data.pull_data.stream_data: 主路径 (实测 2026-06)
                    // 结构: {"options":{"default_quality":{"sdk_key":"hd"},"qualities":[...]},
                    //        "data":{"hd":{"main":{"hls":"...m3u8","flv":"...flv"}},...}}
                    if let lcsd = stream["live_core_sdk_data"] as? [String: Any],
                       let pullData = lcsd["pull_data"] as? [String: Any],
                       let streamDataStr = pullData["stream_data"] as? String,
                       let sd = streamDataStr.data(using: .utf8),
                       let sdObj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any] {
                        let defaultKey: String = {
                            if let opts = sdObj["options"] as? [String: Any],
                               let dq = opts["default_quality"] as? [String: Any],
                               let key = dq["sdk_key"] as? String, !key.isEmpty {
                                return key
                            }
                            return "hd"
                        }()
                        if let data = sdObj["data"] as? [String: Any] {
                            // 默认画质
                            if let quality = data[defaultKey] as? [String: Any],
                               let main = quality["main"] as? [String: Any],
                               let hls = main["hls"] as? String, !hls.isEmpty {
                                hlsURL = hls
                                AppLogger.info("DouyinModels: 抖音 HLS (来自 stream_data) 画质=\(defaultKey) host=\(URL(string: hls)?.host ?? "nil")")
                            }
                            // 扫所有画质,把有 hls 的全收集到 byQuality dict (画质选择 UI 用)
                            for key in ["origin", "uhd", "hd", "sd", "ld"] {
                                if let q = data[key] as? [String: Any],
                                   let main = q["main"] as? [String: Any],
                                   let hls = main["hls"] as? String, !hls.isEmpty,
                                   hlsURLsByQuality[key] == nil {
                                    hlsURLsByQuality[key] = hls
                                }
                            }
                            AppLogger.info("DouyinModels: 抖音可用画质 = \(hlsURLsByQuality.keys.sorted().joined(separator: ","))")
                        }
                }
            }

            let qualityMap = hlsURLsByQuality
            let liveRoomInfo = LiveRoomInfo(
                roomId: roomId,
                title: liveRoomSub?["title"] as? String,
                coverURL: (coverSub?["url_list"] as? [String])?.first,
                // HLS 优先 (AVPlayer 原生支持), FLV 作为兜底
                streamURL: hlsURL ?? flvURL ?? (streamSub?["hls_pull_url"] as? String) ?? (streamSub?["flv_pull_url"] as? String),
                flvURL: flvURL ?? (streamSub?["flv_pull_url"] as? String),
                hlsURL: hlsURL ?? (streamSub?["hls_pull_url"] as? String),
                hlsURLsByQuality: qualityMap,
                viewerCount: viewerCountFromRoomData,
                // room_data 的 status 更准确 (2=直播中), 优先用它
                liveStatus: statusFromRoomData ?? liveStatus
            )
            AppLogger.info("DouyinModels: 最终 LiveRoomInfo.hlsURLsByQuality=\(liveRoomInfo.hlsURLsByQuality.keys.sorted().joined(separator: ","))")
            return liveRoomInfo
        }
        // 没有 room_data (用户没开播或接口未返回), 返回 nil
        return nil
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

        // 一次性把首条视频的关键字段结构 dump 出来,辅助定位问题 (2026-06 已删, 全部结构在 AppLogger.info 已知)
        // [已废弃] 之前 AI 留下, 删了避免编译错

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
                    flvPullURLMap: $0["flv_pull_url"] as? [String: String],
                    hlsPullURL: $0["hls_pull_url"] as? String,
                    hlsPullUrlMap: $0["hls_pull_url_map"] as? [String: String],
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
    let flvPullURLMap: [String: String]?
    let hlsPullURL: String?
    let hlsPullUrlMap: [String: String]?
    let rtmpPullURL: String?
}


// MARK: - DouyinModelsDebug 已废弃,所有一次性诊断代码已删除
// HLS URL 现在从 live_core_sdk_data.pull_data.stream_data.data[default_quality].main.hls 解析
