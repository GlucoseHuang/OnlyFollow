import Foundation

/// iCloud 同步快照的 DTO 集合
///
/// 设计与 SwiftData @Model 解耦：
/// - 写：SyncExporter 从 SwiftData 读出所有记录，转成 DTO，编码成 JSON
/// - 读：SyncCodec 解码 JSON，DTO 被 SyncMerger 写回 SwiftData
/// - 好处：未来 SwiftData schema 变化（加字段、改类型）不会直接破坏 iCloud 文件格式；
///        只要 DTO 格式保持向后兼容，merge 仍能跑
///
/// 时间戳 `lastModifiedAt` 是 merge 的关键：
/// - 收藏 / 关注几乎不变 → lastModifiedAt ≈ addedAt
/// - PlaylistItem.order 会变 → 拖拽时刷新 → "后写获胜"
/// - PlaybackHistory.progressSeconds 持续变 → lastModifiedAt 跟着 watchedAt 走
/// - VideoRecord 每次 API 拉取都会刷新 → lastModifiedAt ≈ lastRefreshedAt

// MARK: - 顶层快照

struct SyncSnapshot: Codable, Sendable {
    /// 快照格式版本号；未来不兼容的格式变更就 +1 并在 merger 里分支处理
    let schemaVersion: Int
    /// 写快照的设备 ID（同一 iCloud 账户下多设备唯一）
    /// 用 UUID + iCloud 账户 token 的方式构造，防止两台设备碰巧 ID 撞了
    let deviceID: String
    /// 快照生成时间（设备本地时间）
    let generatedAt: Date
    let creators: [CreatorDTO]
    let favorites: [FavoriteDTO]
    let playlist: [PlaylistDTO]
    let history: [HistoryDTO]
    let videos: [VideoDTO]
    let liveHistory: [LiveHistoryDTO]

    static let currentSchemaVersion = 1

    /// 显式 memberwise init：自定义 decoder 之后合成版本就不再生成了，
    /// SyncExporter 里还要靠这个构造新快照
    init(
        schemaVersion: Int,
        deviceID: String,
        generatedAt: Date,
        creators: [CreatorDTO],
        favorites: [FavoriteDTO],
        playlist: [PlaylistDTO],
        history: [HistoryDTO],
        videos: [VideoDTO],
        liveHistory: [LiveHistoryDTO]
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.generatedAt = generatedAt
        self.creators = creators
        self.favorites = favorites
        self.playlist = playlist
        self.history = history
        self.videos = videos
        self.liveHistory = liveHistory
    }

    /// 自定义 decoder：liveHistory 是后加的字段（v1 快照里没有），
    /// 用 decodeIfPresent 容忍缺失，老快照能继续读
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        creators = try c.decode([CreatorDTO].self, forKey: .creators)
        favorites = try c.decode([FavoriteDTO].self, forKey: .favorites)
        playlist = try c.decode([PlaylistDTO].self, forKey: .playlist)
        history = try c.decode([HistoryDTO].self, forKey: .history)
        videos = try c.decode([VideoDTO].self, forKey: .videos)
        liveHistory = try c.decodeIfPresent([LiveHistoryDTO].self, forKey: .liveHistory) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceID, generatedAt
        case creators, favorites, playlist, history, videos, liveHistory
    }
}

// MARK: - 各实体 DTO

struct CreatorDTO: Codable, Sendable {
    var uid: String
    var platform: String
    var nickname: String
    var avatarURL: String
    var addedAt: Date
    var bulkFetchCompletedAt: Date?
    var bulkFetchNextPage: Int
    var bulkFetchTotal: Int
    var hasCompletedInitialSync: Bool
    var lastModifiedAt: Date
}

struct FavoriteDTO: Codable, Sendable {
    var aid: Int
    var bvid: String
    var title: String
    var coverURL: String
    var duration: Int
    var publishTime: Date
    var viewCount: Int
    var danmakuCount: Int
    var commentCount: Int
    var authorUID: String
    var authorName: String
    var authorAvatar: String
    var platform: String
    var addedAt: Date
    var lastModifiedAt: Date
}

struct PlaylistDTO: Codable, Sendable {
    var aid: Int
    var bvid: String
    var title: String
    var coverURL: String
    var duration: Int
    var publishTime: Date
    var viewCount: Int
    var danmakuCount: Int
    var commentCount: Int
    var authorUID: String
    var authorName: String
    var authorAvatar: String
    var platform: String
    var order: Int
    var addedAt: Date
    var lastModifiedAt: Date
}

struct HistoryDTO: Codable, Sendable {
    var aid: Int
    var title: String
    var coverURL: String
    var duration: Int
    var authorUID: String
    var authorName: String
    var platform: String
    var progressSeconds: Int
    /// 最后观看的分 P 的 cid(0 表示单 P 视频或还没记录)
    var partCid: Int
    /// 最后观看的分 P 的 1-based 页码(0 表示单 P 视频或还没记录)
    var partPage: Int
    /// 最后观看的分 P 的标题
    var partTitle: String
    var watchedAt: Date
    var lastModifiedAt: Date

    /// 自定义 decoder: partCid/partPage/partTitle 是后加的字段(老 snapshot 没有)
    /// 用 decodeIfPresent 容忍缺失,缺失时按"单 P 视频"处理
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aid = try c.decode(Int.self, forKey: .aid)
        title = try c.decode(String.self, forKey: .title)
        coverURL = try c.decode(String.self, forKey: .coverURL)
        duration = try c.decode(Int.self, forKey: .duration)
        authorUID = try c.decode(String.self, forKey: .authorUID)
        authorName = try c.decode(String.self, forKey: .authorName)
        platform = try c.decode(String.self, forKey: .platform)
        progressSeconds = try c.decode(Int.self, forKey: .progressSeconds)
        partCid = try c.decodeIfPresent(Int.self, forKey: .partCid) ?? 0
        partPage = try c.decodeIfPresent(Int.self, forKey: .partPage) ?? 0
        partTitle = try c.decodeIfPresent(String.self, forKey: .partTitle) ?? ""
        watchedAt = try c.decode(Date.self, forKey: .watchedAt)
        lastModifiedAt = try c.decode(Date.self, forKey: .lastModifiedAt)
    }

    init(aid: Int, title: String, coverURL: String, duration: Int, authorUID: String, authorName: String, platform: String, progressSeconds: Int, partCid: Int, partPage: Int, partTitle: String, watchedAt: Date, lastModifiedAt: Date) {
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.duration = duration
        self.authorUID = authorUID
        self.authorName = authorName
        self.platform = platform
        self.progressSeconds = progressSeconds
        self.partCid = partCid
        self.partPage = partPage
        self.partTitle = partTitle
        self.watchedAt = watchedAt
        self.lastModifiedAt = lastModifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case aid, title, coverURL, duration, authorUID, authorName, platform
        case progressSeconds, partCid, partPage, partTitle, watchedAt, lastModifiedAt
    }
}

struct VideoDTO: Codable, Sendable {
    var aid: Int
    var platform: String
    var bvid: String
    var title: String
    var coverURL: String
    var webURL: String
    var duration: Int
    var publishTime: Date
    var viewCount: Int
    var danmakuCount: Int
    var commentCount: Int
    var authorUID: String
    var authorName: String
    var authorAvatar: String
    var firstSeenAt: Date
    var lastRefreshedAt: Date
    var titleTokens: String
    var authorTokens: String
    /// B 站 UGC 合集 ID(可选). v2 字段; 老 snapshot 不带时解码为 nil, 跟本地现有的 nil 兼容.
    var ugcSeasonID: Int?
    /// B 站 UGC 合集标题(可选). v2 字段.
    var ugcSeasonTitle: String?
    var lastModifiedAt: Date
}


struct LiveHistoryDTO: Codable, Sendable {
    var roomID: Int
    var title: String
    var coverURL: String
    var authorUID: String
    var authorName: String
    var authorAvatar: String
    var platform: String
    var watchedAt: Date
    var lastModifiedAt: Date
}

// MARK: - DTO → VideoItem

extension VideoDTO {
    /// 转换为 VideoItem,用于填充 VideoCache 给首页 / 详情页展示
    /// - cid/playURL 不在 DTO 里(播放页另行拉),保持空字符串即可
    func toVideoItem() -> VideoItem {
        VideoItem(
            id: String(aid),
            aid: aid,
            bvid: bvid,
            cid: 0,
            title: title,
            coverURL: coverURL,
            playURL: "",
            webURL: webURL,
            duration: duration,
            publishTime: publishTime,
            viewCount: viewCount,
            danmakuCount: danmakuCount,
            commentCount: commentCount,
            authorUID: authorUID,
            authorName: authorName,
            authorAvatar: authorAvatar,
            platform: platform,
            ugcSeasonID: ugcSeasonID,
            ugcSeasonTitle: ugcSeasonTitle
        )
    }
}
