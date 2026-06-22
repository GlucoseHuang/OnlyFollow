import Foundation

// MARK: - User Info

struct BilibiliUserInfo: Codable, Sendable {
    let mid: Int
    let name: String
    let face: String
    let sign: String
    let liveRoom: LiveRoomInfo?

    struct LiveRoomInfo: Codable, Sendable {
        let roomid: Int
        let liveStatus: Int
        let title: String
        let cover: String
        let url: String?
        enum CodingKeys: String, CodingKey { case roomid, liveStatus, title, cover, url }
        var isLiving: Bool { liveStatus == 1 }
    }

    enum CodingKeys: String, CodingKey {
        case mid, name, face, sign
        case liveRoom = "live_room"
    }
}

// MARK: - Video List

struct BilibiliVideoListResponse: Codable, Sendable {
    let list: VideoList
    struct VideoList: Codable, Sendable { let vlist: [BilibiliVideoItem] }
    /// count = 该 UP 主的总视频数；pn = 当前页；ps = 单页大小
    /// 用于「全量历史拉取」的终止判定
    let page: PageInfo?
    struct PageInfo: Codable, Sendable {
        let count: Int
        let pn: Int
        let ps: Int
    }

    struct BilibiliVideoItem: Codable, Sendable {
        let aid: Int
        let bvid: String
        let title: String
        let pic: String
        let length: String
        let created: Int
        let play: Int
        let comment: Int
        let videoReview: Int
        let author: String

        // B站 API 部分字段是 snake_case (video_review)，
        // Swift 默认 Codable 不做转换，必须显式 CodingKeys 映射
        enum CodingKeys: String, CodingKey {
            case aid, bvid, title, pic, length, created, play, comment, author
            case videoReview = "video_review"
        }

        func toVideoItem(authorUID: String, authorAvatar: String = "") -> VideoItem {
            VideoItem(
                id: "\(aid)",
                aid: aid,
                bvid: bvid,
                cid: 0, // cid 需要点进详情时通过 fetchVideoDetail 获取
                title: title,
                coverURL: ensureHTTPS(pic),
                playURL: "",
                webURL: "https://www.bilibili.com/video/av\(aid)",
                duration: parseDuration(length),
                publishTime: Date(timeIntervalSince1970: TimeInterval(created)),
                viewCount: play,
                danmakuCount: videoReview,
                commentCount: comment,
                authorUID: authorUID,
                authorName: author,
                authorAvatar: authorAvatar,
                platform: "bilibili",
                ugcSeasonID: nil,
                ugcSeasonTitle: nil
            )
        }

        private func parseDuration(_ s: String) -> Int {
            let parts = s.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            return 0
        }
    }
}

// MARK: - Video Detail

struct BilibiliVideoDetail: Codable, Sendable {
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let pic: String
    let duration: Int
    let pubdate: Int
    let stat: Stat
    let owner: Owner
    /// 该视频所属的 UGC 合集(season)对象。B 站 `web-interface/view` 在合集视频里会返回
    /// `data.ugc_season = { id, title, cover, ... }`, 非合集视频里这个字段是 null 或不存在。
    /// 之前误以为是顶级的 `ugc_season_id` 字段, 所以一直没解析到 — 这就是合集按钮不弹的根本原因。
    let ugcSeason: UGCSeason?
    /// 视频分 P 列表(`data.pages[]`)。单 P 视频长度为 1; 多 P 视频按时间正序排列。
    /// 列表/合集 API 不返回 pages, 只有 fetchVideoDetail 才返回; 播放器每次进都会拉 view, 直接复用即可, 不用额外请求 pagelist.
    let pages: [BilibiliVideoPart]?

    struct UGCSeason: Codable, Sendable {
        let id: Int
        let title: String?
        let cover: String?
    }

    /// 便捷访问: 合集 ID(没有合集时为 nil)
    var ugcSeasonID: Int? { ugcSeason?.id }
    /// 该视频是否有多个分 P（自动连播 + 分P按钮的判定依据）
    var hasMultipleParts: Bool { (pages?.count ?? 0) > 1 }

    /// Swift 默认 Codable 是按字段名同名匹配, JSON 里是 `ugc_season`, 这里需要显式映射
    private enum CodingKeys: String, CodingKey {
        case aid, bvid, cid, title, pic, duration, pubdate, stat, owner
        case ugcSeason = "ugc_season"
        case pages
    }

    struct Stat: Codable, Sendable {
        let view: Int
        let reply: Int
        let danmaku: Int
        let favorite: Int
        let coin: Int
        let share: Int
        let like: Int
    }
    struct Owner: Codable, Sendable { let mid: Int; let name: String; let face: String }

    func toVideoItem() -> VideoItem {
        VideoItem(
            id: "\(aid)",
            aid: aid,
            bvid: bvid,
            cid: cid,
            title: title,
            coverURL: ensureHTTPS(pic),
            playURL: "",
            webURL: "https://www.bilibili.com/video/av\(aid)",
            duration: duration,
            publishTime: Date(timeIntervalSince1970: TimeInterval(pubdate)),
            viewCount: stat.view,
            danmakuCount: stat.danmaku,
            commentCount: stat.reply,
            authorUID: "\(owner.mid)",
            authorName: owner.name,
            authorAvatar: ensureHTTPS(owner.face),
            platform: "bilibili",
            ugcSeasonID: ugcSeason?.id,
            ugcSeasonTitle: ugcSeason?.title
        )
    }
}

// MARK: - Live Room

struct BilibiliLiveRoomResponse: Codable, Sendable {
    let roomID: Int
    let title: String
    let cover: String
    let online: Int
    let uid: Int
    let uname: String
    let uface: String
    let liveStatus: Int

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", title, cover, online, uid, uname, uface, liveStatus = "live_status"
    }

    func toLiveRoom() -> LiveRoom {
        LiveRoom(
            id: "\(roomID)", roomID: "\(roomID)", title: title,
            coverURL: ensureHTTPS(cover), streamURL: "",
            viewerCount: online, authorUID: "\(uid)", authorName: uname,
            authorAvatar: ensureHTTPS(uface), platform: "bilibili", isLive: liveStatus == 1
        )
    }
}

// MARK: - Danmu Info

struct BilibiliDanmuInfo: Codable, Sendable {
    let data: DanmuData
    struct DanmuData: Codable, Sendable {
        let token: String
        let hostList: [HostInfo]
        enum CodingKeys: String, CodingKey { case token; case hostList = "host_list" }
    }
    struct HostInfo: Codable, Sendable { let host: String; let port: Int; let wssPort: Int }
}

// MARK: - Comments

/// B站 /x/v2/reply/wbi/main 接口 data 字段的实际结构
struct BilibiliCommentResponse: Codable, Sendable {
    let replies: [BilibiliComment]?
    let cursor: Cursor?
    struct Cursor: Codable, Sendable {
        let paginationReply: PaginationReply?
        enum CodingKeys: String, CodingKey {
            case paginationReply = "pagination_reply"
        }
        struct PaginationReply: Codable, Sendable {
            let nextOffset: String
            enum CodingKeys: String, CodingKey {
                case nextOffset = "next_offset"
            }
        }
    }
}

struct BilibiliComment: Codable, Identifiable, Sendable {
    /// B 站评论 ID（原字段是 rpid）
    let rpid: Int
    let ctime: Int?
    let like: Int?
    let content: Content
    let member: Member
    let replies: [BilibiliComment]?

    var id: Int { rpid }
    var idString: String { String(rpid) }

    struct Content: Codable, Sendable {
        let message: String
    }
    struct Member: Codable, Sendable {
        /// B 站实际是字符串类型（"123456"）不是 Int
        let mid: String?
        let uname: String?
        /// B 站 API 字段名是 avatar（不是 face 也不是 avatar_url）
        let avatar: String?
    }

    /// B 站响应里字段很多（rpid_str, root, parent, count, folder, up_action, show_follow, invisible, ...），
    /// 我们只关心其中几个；其他全部忽略
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rpid = try c.decode(Int.self, forKey: .rpid)
        ctime = try c.decodeIfPresent(Int.self, forKey: .ctime)
        like = try c.decodeIfPresent(Int.self, forKey: .like)
        content = try c.decode(Content.self, forKey: .content)
        member = try c.decode(Member.self, forKey: .member)
        replies = try c.decodeIfPresent([BilibiliComment].self, forKey: .replies)
    }

    enum CodingKeys: String, CodingKey {
        case rpid, ctime, like, content, member, replies
    }
}

// MARK: - Helper

/// B 站图片 URL 经常是 http://，iOS ATS 不允许，需要转 https://
func ensureHTTPS(_ url: String) -> String {
    if url.hasPrefix("http://") {
        return "https://" + url.dropFirst(7)
    }
    return url
}

// MARK: - Live Play Info (直播流地址 v2 接口)

/// /xlive/web-room/v2/index/getRoomPlayInfo 响应
/// 完整结构: data.playurl_info.playurl.stream[].format[].codec[].url_info[]
/// 只需要从中挑第一条 HLS（http_hls）+ AVC 编码的 m3u8 即可，AVPlayer 原生支持
struct BilibiliLivePlayInfoResponse: Codable, Sendable {
    let playurlInfo: PlayurlInfo?

    enum CodingKeys: String, CodingKey {
        case playurlInfo = "playurl_info"
    }

    struct PlayurlInfo: Codable, Sendable {
        let playurl: Playurl?
        /// 服务端当前给的实际清晰度（与请求 qn 配合看是否降级）
        let currentQn: Int?
        /// 该房间所有可用清晰度编号列表
        let acceptQuality: [Int]?

        enum CodingKeys: String, CodingKey {
            case playurl
            case currentQn = "current_qn"
            case acceptQuality = "accept_quality"
        }
    }

    struct Playurl: Codable, Sendable {
        let stream: [Stream]?
    }

    struct Stream: Codable, Sendable {
        let protocolName: String
        let format: [Format]?

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol_name"
            case format
        }
    }

    struct Format: Codable, Sendable {
        let formatName: String
        let codec: [Codec]?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case codec
        }
    }

    struct Codec: Codable, Sendable {
        let codecName: String
        let baseURL: String?
        let urlInfo: [URLInfo]?

        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case baseURL = "base_url"
            case urlInfo = "url_info"
        }
    }

    struct URLInfo: Codable, Sendable {
        let host: String
        let extra: String
        let streamTTL: Int?

        enum CodingKeys: String, CodingKey {
            case host, extra
            case streamTTL = "stream_ttl"
        }
    }
}

extension BilibiliLivePlayInfoResponse.Playurl {
    /// 在所有流里挑第一个 "http_hls + ts/fmp4 + AVC" 组合的 m3u8 URL
    /// - 协议过滤：只要 http_hls（http_stream 实际就是 FLV，AVPlayer 播不了）
    /// - 容器过滤：只要 ts / fmp4（不要 flv）
    /// - 编码过滤：只要 avc（不要 hevc）
    /// B 站接口参数 protocol=0,1, format=0,1,2, codec=0,1 通常能满足这些条件
    func firstHLSStreamURL() -> String? {
        guard let streams = stream else { return nil }
        for stream in streams where stream.protocolName == "http_hls" {
            guard let formats = stream.format else { continue }
            for format in formats where format.formatName == "ts" || format.formatName == "fmp4" {
                guard let codecs = format.codec else { continue }
                for codec in codecs where codec.codecName == "avc" {
                    guard let baseURL = codec.baseURL,
                          let urlInfo = codec.urlInfo?.first else { continue }
                    // m3u8 完整 URL = host + base_url + extra
                    // base_url 形如 /live-bvc/.../index.m3u8
                    // extra 形如 ?expires=...&sign=...&sig=...
                    return "\(urlInfo.host)\(baseURL)\(urlInfo.extra)"
                }
            }
        }
        return nil
    }
}


// MARK: - UGC Season（合集）

/// /x/polymer/web-space/seasons_archives_list 响应
/// 用于"播完当前视频后自动播合集下一个"和"在播放页展示合集视频列表"
struct BilibiliSeasonArchivesResponse: Codable, Sendable {
    let archives: [Archive]
    let meta: Meta?
    let page: Page?
    let aids: [Int]?

    struct Archive: Codable, Sendable {
        let aid: Int
        let bvid: String
        let title: String
        let pic: String
        let duration: Int
        let pubdate: Int
        let ctime: Int?
        let stat: Stat?
        struct Stat: Codable, Sendable { let view: Int? }
        /// playback_position: 0 = 没看过,1-99 = 百分比, -1 = 看完
        let playbackPosition: Int?
        enum CodingKeys: String, CodingKey {
            case aid, bvid, title, pic, duration, pubdate, ctime, stat
            case playbackPosition = "playback_position"
        }
        /// 转成项目的 VideoItem。注意 mid/name 不在这个接口里,
        /// 合集外的元数据从 VideoRecord 补,补不到就留空
        func toVideoItem(authorUID: String, authorName: String) -> VideoItem {
            VideoItem(
                id: String(aid),
                aid: aid,
                bvid: bvid,
                cid: 0,  // 进播放时再 fetchVideoDetail 拿
                title: title,
                coverURL: ensureHTTPS(pic),
                playURL: "",
                webURL: "https://www.bilibili.com/video/av\(aid)",
                duration: duration,
                publishTime: Date(timeIntervalSince1970: TimeInterval(pubdate)),
                viewCount: stat?.view ?? 0,
                danmakuCount: 0,
                commentCount: 0,
                authorUID: authorUID,
                authorName: authorName,
                authorAvatar: "",
                platform: "bilibili",
                ugcSeasonID: nil,  // 合集内视频再嵌套合集不现实
                ugcSeasonTitle: nil
            )
        }
    }

    struct Meta: Codable, Sendable {
        let name: String
        let description: String?
        let cover: String?
        let mid: Int
        let seasonID: Int
        let total: Int
        enum CodingKeys: String, CodingKey {
            case name, description, cover, mid, total
            case seasonID = "season_id"
        }
    }

    struct Page: Codable, Sendable {
        let total: Int
        let pageNum: Int
        let pageSize: Int
        enum CodingKeys: String, CodingKey {
            case total
            case pageNum = "page_num"
            case pageSize = "page_size"
        }
    }
}


// MARK: - 视频分 P（用于多 P 视频的自动连播 + 分 P 列表）

/// B 站视频的单个分 P。
/// - 字段含义详见 SocialSisterYi/bilibili-API-collect docs/video/info.md (data.pages[])
/// - 单 P 视频的 `pages` 也是长度为 1 的数组, 所以这套逻辑对单 P 也是安全的
struct BilibiliVideoPart: Codable, Sendable {
    let cid: Int
    let page: Int
    let part: String
    let duration: Int
    /// 部分老视频没有 resolution 字段, 所以做成可选
    let dimension: PartDimension?

    struct PartDimension: Codable, Sendable {
        let width: Int?
        let height: Int?
        let rotate: Int?
    }
}
