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
                platform: "bilibili"
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
            platform: "bilibili"
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
