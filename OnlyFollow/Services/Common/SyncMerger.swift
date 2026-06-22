import Foundation
import SwiftData

/// SyncSnapshot → 本地 SwiftData 的合并
///
/// 合并规则（per entity type）：
/// 1. 用自然键（uid / aid）建本地记录索引
/// 2. 对快照里每条 DTO：
///    - 本地没有 → 插入
///    - 本地有 → 比较 lastModifiedAt；远程更新就覆盖本地
/// 3. 不删除本地"快照里没有"的记录（保留可能是本地新加的）
///
/// 含义：
/// - 两台设备都是"追加"行为（收藏 / 关注 / 历史）→ 同步后 = 双方并集 ✓
/// - PlaylistItem.order 改了一台 → lastModifiedAt 更新 → 后写获胜（你拍板的方案）✓
/// - PlaybackHistory.progressSeconds 改了一台 → 看视频的那台时间更新 → 续播体验 ✓
/// - VideoRecord 拉了新数据的那台 lastModifiedAt 更新 → 数据被传播 ✓
///
/// 不处理：
/// - 删除传播：用户在 iPhone 删了一条收藏，iPad 上仍存在
///   → 收藏/关注/历史都是单调追加，删除极少；V1 忽略
/// - 字段级冲突：整条记录"后写获胜"
///   → 用户能接受的简化，PlayListItem.order 也按此走
/// 注意:故意不在 @MainActor。merge 函数体里有大量 SwiftData 操作(插入 2200+ 条记录),
/// 历史上放在主 actor 上会把主线程阻塞数秒(iOS 17/18 SwiftData save 已知问题)。
/// 调用方(SyncCoordinator)用 Task.detached + 后台 ModelContext 触发 merge,
/// SwiftData 的 background context save 完后会自动 propagate 到主 context。
enum SyncMerger {
    /// 合并一个快照到本地
    /// - snapshot: 来自 iCloud 的远程快照（可能为本设备刚写的；调用方负责判断要不要跳过）
    /// - 返回：每个 entity 类型的合并统计（inserted / updated / kept）
    @discardableResult
    static func merge(_ snapshot: SyncSnapshot, into context: ModelContext) throws -> MergeStats {
        var stats = MergeStats()

        try mergeCreators(snapshot.creators, into: context, stats: &stats)
        try mergeFavorites(snapshot.favorites, into: context, stats: &stats)
        try mergePlaylist(snapshot.playlist, into: context, stats: &stats)
        try mergeHistory(snapshot.history, into: context, stats: &stats)
        try mergeVideos(snapshot.videos, into: context, stats: &stats)
        try mergeLiveHistory(snapshot.liveHistory, into: context, stats: &stats)

        // 一次 save 提交所有变更
        do {
            try context.save()
        } catch {
            AppLogger.error("SyncMerger: context.save failed: \(error.localizedDescription)")
            throw error
        }
        AppLogger.info("SyncMerger: merged snapshot from device=\(snapshot.deviceID.prefix(8))... — \(stats.summary)")
        return stats
    }

    // MARK: - 各实体

    private static func mergeCreators(_ dtos: [CreatorDTO], into context: ModelContext, stats: inout MergeStats) throws {
        guard !dtos.isEmpty else { return }
        let uids = dtos.map(\.uid)
        let predicate = #Predicate<FollowedCreator> { uids.contains($0.uid) }
        let existing = (try? context.fetch(FetchDescriptor<FollowedCreator>(predicate: predicate))) ?? []
        var byUID: [String: FollowedCreator] = [:]
        for c in existing { byUID[c.uid] = c }

        for d in dtos {
            if let local = byUID[d.uid] {
                if d.lastModifiedAt > local.lastModifiedAt {
                    local.nickname = d.nickname
                    local.avatarURL = d.avatarURL
                    local.platform = d.platform
                    local.addedAt = d.addedAt
                    local.bulkFetchCompletedAt = d.bulkFetchCompletedAt
                    local.bulkFetchNextPage = d.bulkFetchNextPage
                    local.bulkFetchTotal = d.bulkFetchTotal
                    local.hasCompletedInitialSync = d.hasCompletedInitialSync
                    local.lastModifiedAt = d.lastModifiedAt
                    stats.creatorsUpdated += 1
                } else {
                    stats.creatorsKept += 1
                }
            } else {
                let c = FollowedCreator(
                    uid: d.uid,
                    platform: d.platform,
                    nickname: d.nickname,
                    avatarURL: d.avatarURL,
                    addedAt: d.addedAt
                )
                c.bulkFetchCompletedAt = d.bulkFetchCompletedAt
                c.bulkFetchNextPage = d.bulkFetchNextPage
                c.bulkFetchTotal = d.bulkFetchTotal
                c.hasCompletedInitialSync = d.hasCompletedInitialSync
                c.lastModifiedAt = d.lastModifiedAt
                context.insert(c)
                stats.creatorsInserted += 1
            }
        }
    }

    private static func mergeFavorites(_ dtos: [FavoriteDTO], into context: ModelContext, stats: inout MergeStats) throws {
        guard !dtos.isEmpty else { return }
        let aids = dtos.map(\.aid)
        let predicate = #Predicate<FavoriteVideo> { aids.contains($0.aid) }
        let existing = (try? context.fetch(FetchDescriptor<FavoriteVideo>(predicate: predicate))) ?? []
        var byAid: [Int: FavoriteVideo] = [:]
        for f in existing { byAid[f.aid] = f }

        for d in dtos {
            if let local = byAid[d.aid] {
                if d.lastModifiedAt > local.lastModifiedAt {
                    local.title = d.title
                    local.coverURL = d.coverURL
                    local.duration = d.duration
                    local.publishTime = d.publishTime
                    local.viewCount = d.viewCount
                    local.danmakuCount = d.danmakuCount
                    local.commentCount = d.commentCount
                    local.authorUID = d.authorUID
                    local.authorName = d.authorName
                    local.authorAvatar = d.authorAvatar
                    local.platform = d.platform
                    local.addedAt = d.addedAt
                    local.lastModifiedAt = d.lastModifiedAt
                    stats.favoritesUpdated += 1
                } else {
                    stats.favoritesKept += 1
                }
            } else {
                let f = FavoriteVideoDTOApplier.make(from: d)
                context.insert(f)
                stats.favoritesInserted += 1
            }
        }
    }

    private static func mergePlaylist(_ dtos: [PlaylistDTO], into context: ModelContext, stats: inout MergeStats) throws {
        guard !dtos.isEmpty else { return }
        let aids = dtos.map(\.aid)
        let predicate = #Predicate<PlaylistItem> { aids.contains($0.aid) }
        let existing = (try? context.fetch(FetchDescriptor<PlaylistItem>(predicate: predicate))) ?? []
        var byAid: [Int: PlaylistItem] = [:]
        for p in existing { byAid[p.aid] = p }

        for d in dtos {
            if let local = byAid[d.aid] {
                if d.lastModifiedAt > local.lastModifiedAt {
                    local.title = d.title
                    local.coverURL = d.coverURL
                    local.duration = d.duration
                    local.publishTime = d.publishTime
                    local.viewCount = d.viewCount
                    local.danmakuCount = d.danmakuCount
                    local.commentCount = d.commentCount
                    local.authorUID = d.authorUID
                    local.authorName = d.authorName
                    local.authorAvatar = d.authorAvatar
                    local.platform = d.platform
                    local.order = d.order
                    local.addedAt = d.addedAt
                    local.lastModifiedAt = d.lastModifiedAt
                    stats.playlistUpdated += 1
                } else {
                    stats.playlistKept += 1
                }
            } else {
                let p = PlaylistItemDTOApplier.make(from: d)
                context.insert(p)
                stats.playlistInserted += 1
            }
        }
    }

    private static func mergeHistory(_ dtos: [HistoryDTO], into context: ModelContext, stats: inout MergeStats) throws {
        guard !dtos.isEmpty else { return }
        let aids = dtos.map(\.aid)
        let predicate = #Predicate<PlaybackHistory> { aids.contains($0.aid) }
        let existing = (try? context.fetch(FetchDescriptor<PlaybackHistory>(predicate: predicate))) ?? []
        var byAid: [Int: PlaybackHistory] = [:]
        for h in existing { byAid[h.aid] = h }

        for d in dtos {
            if let local = byAid[d.aid] {
                if d.lastModifiedAt > local.lastModifiedAt {
                    local.title = d.title
                    local.coverURL = d.coverURL
                    local.duration = d.duration
                    local.authorUID = d.authorUID
                    local.authorName = d.authorName
                    local.platform = d.platform
                    local.progressSeconds = d.progressSeconds
                    // 分 P 字段: 远端 0/空表示"老快照没有这个字段"或"单 P 视频",
                    // 不应该把本地有效的分 P 信息抹掉。
                    // 只在远端真的有有效值时才覆盖。
                    if d.partCid > 0 { local.partCid = d.partCid }
                    if d.partPage > 0 { local.partPage = d.partPage }
                    if !d.partTitle.isEmpty { local.partTitle = d.partTitle }
                    local.watchedAt = d.watchedAt
                    local.lastModifiedAt = d.lastModifiedAt
                    stats.historyUpdated += 1
                } else {
                    stats.historyKept += 1
                }
            } else {
                let h = PlaybackHistoryDTOApplier.make(from: d)
                context.insert(h)
                stats.historyInserted += 1
            }
        }
    }

    private static func mergeVideos(_ dtos: [VideoDTO], into context: ModelContext, stats: inout MergeStats) throws {
        guard !dtos.isEmpty else { return }
        let aids = dtos.map(\.aid)
        let predicate = #Predicate<VideoRecord> { aids.contains($0.aid) }
        let existing = (try? context.fetch(FetchDescriptor<VideoRecord>(predicate: predicate))) ?? []
        var byAid: [Int: VideoRecord] = [:]
        for v in existing { byAid[v.aid] = v }

        for d in dtos {
            if let local = byAid[d.aid] {
                if d.lastModifiedAt > local.lastModifiedAt {
                    local.platform = d.platform
                    local.bvid = d.bvid
                    local.title = d.title
                    local.coverURL = d.coverURL
                    local.webURL = d.webURL
                    local.duration = d.duration
                    local.publishTime = d.publishTime
                    local.viewCount = d.viewCount
                    local.danmakuCount = d.danmakuCount
                    local.commentCount = d.commentCount
                    local.authorUID = d.authorUID
                    local.authorName = d.authorName
                    local.authorAvatar = d.authorAvatar
                    local.firstSeenAt = d.firstSeenAt
                    local.lastRefreshedAt = d.lastRefreshedAt
                    local.titleTokens = d.titleTokens
                    local.authorTokens = d.authorTokens
                    // 合集 ID/标题: 老 snapshot 没这两个字段时是 nil, 不会覆盖 local 的有效值
                    if let sid = d.ugcSeasonID { local.ugcSeasonID = sid }
                    if let st = d.ugcSeasonTitle { local.ugcSeasonTitle = st }
                    local.lastModifiedAt = d.lastModifiedAt
                    stats.videosUpdated += 1
                } else {
                    stats.videosKept += 1
                }
            } else {
                let v = VideoRecordDTOApplier.make(from: d)
                context.insert(v)
                stats.videosInserted += 1
            }
        }
    }

    private static func mergeLiveHistory(_ dtos: [LiveHistoryDTO], into context: ModelContext, stats: inout MergeStats) throws {
        guard !dtos.isEmpty else { return }
        let roomIDs = dtos.map(\.roomID)
        let predicate = #Predicate<LiveHistory> { roomIDs.contains($0.roomID) }
        let existing = (try? context.fetch(FetchDescriptor<LiveHistory>(predicate: predicate))) ?? []
        var byRoomID: [Int: LiveHistory] = [:]
        for h in existing { byRoomID[h.roomID] = h }

        for d in dtos {
            if let local = byRoomID[d.roomID] {
                if d.lastModifiedAt > local.lastModifiedAt {
                    local.title = d.title
                    local.coverURL = d.coverURL
                    local.authorUID = d.authorUID
                    local.authorName = d.authorName
                    local.authorAvatar = d.authorAvatar
                    local.platform = d.platform
                    local.watchedAt = d.watchedAt
                    local.lastModifiedAt = d.lastModifiedAt
                    stats.liveHistoryUpdated += 1
                } else {
                    stats.liveHistoryKept += 1
                }
            } else {
                let h = LiveHistoryDTOApplier.make(from: d)
                context.insert(h)
                stats.liveHistoryInserted += 1
            }
        }
    }
}

// MARK: - 统计

struct MergeStats {
    var creatorsInserted = 0
    var creatorsUpdated = 0
    var creatorsKept = 0
    var favoritesInserted = 0
    var favoritesUpdated = 0
    var favoritesKept = 0
    var playlistInserted = 0
    var playlistUpdated = 0
    var playlistKept = 0
    var historyInserted = 0
    var historyUpdated = 0
    var historyKept = 0
    var videosInserted = 0
    var videosUpdated = 0
    var videosKept = 0

    var totalChanges: Int {
        creatorsInserted + creatorsUpdated +
        favoritesInserted + favoritesUpdated +
        playlistInserted + playlistUpdated +
        historyInserted + historyUpdated +
        videosInserted + videosUpdated
    }

    var liveHistoryInserted: Int = 0
    var liveHistoryUpdated: Int = 0
    var liveHistoryKept: Int = 0

    var summary: String {
        "creators +\(creatorsInserted)/~\(creatorsUpdated), fav +\(favoritesInserted)/~\(favoritesUpdated), pl +\(playlistInserted)/~\(playlistUpdated), hist +\(historyInserted)/~\(historyUpdated), vid +\(videosInserted)/~\(videosUpdated), liveHist +\(liveHistoryInserted)/~\(liveHistoryUpdated)"
    }
}

// MARK: - DTO → @Model 工厂

/// FavoriteVideo 的 init 接受 VideoItem；这里绕一下：从 DTO 重建
private enum FavoriteVideoDTOApplier {
    static func make(from d: FavoriteDTO) -> FavoriteVideo {
        let item = VideoItem(
            id: String(d.aid),
            aid: d.aid,
            bvid: d.bvid,
            cid: 0,
            title: d.title,
            coverURL: d.coverURL,
            playURL: "",
            webURL: "https://www.bilibili.com/video/av\(d.aid)",
            duration: d.duration,
            publishTime: d.publishTime,
            viewCount: d.viewCount,
            danmakuCount: d.danmakuCount,
            commentCount: d.commentCount,
            authorUID: d.authorUID,
            authorName: d.authorName,
            authorAvatar: d.authorAvatar,
            platform: d.platform,
            ugcSeasonID: nil,
            ugcSeasonTitle: nil
        )
        let f = FavoriteVideo(video: item)
        f.addedAt = d.addedAt
        f.lastModifiedAt = d.lastModifiedAt
        return f
    }
}

private enum PlaylistItemDTOApplier {
    static func make(from d: PlaylistDTO) -> PlaylistItem {
        let item = VideoItem(
            id: String(d.aid),
            aid: d.aid,
            bvid: d.bvid,
            cid: 0,
            title: d.title,
            coverURL: d.coverURL,
            playURL: "",
            webURL: "https://www.bilibili.com/video/av\(d.aid)",
            duration: d.duration,
            publishTime: d.publishTime,
            viewCount: d.viewCount,
            danmakuCount: d.danmakuCount,
            commentCount: d.commentCount,
            authorUID: d.authorUID,
            authorName: d.authorName,
            authorAvatar: d.authorAvatar,
            platform: d.platform,
            ugcSeasonID: nil,
            ugcSeasonTitle: nil
        )
        let p = PlaylistItem(video: item, order: d.order)
        p.addedAt = d.addedAt
        p.lastModifiedAt = d.lastModifiedAt
        return p
    }
}

private enum LiveHistoryDTOApplier {
    static func make(from d: LiveHistoryDTO) -> LiveHistory {
        let h = LiveHistory(
            roomID: d.roomID,
            title: d.title,
            coverURL: d.coverURL,
            authorUID: d.authorUID,
            authorName: d.authorName,
            authorAvatar: d.authorAvatar,
            platform: d.platform,
            watchedAt: d.watchedAt
        )
        h.lastModifiedAt = d.lastModifiedAt
        return h
    }
}

private enum PlaybackHistoryDTOApplier {
    static func make(from d: HistoryDTO) -> PlaybackHistory {
        let item = VideoItem(
            id: String(d.aid),
            aid: d.aid,
            bvid: "",
            cid: 0,
            title: d.title,
            coverURL: d.coverURL,
            playURL: "",
            webURL: "https://www.bilibili.com/video/av\(d.aid)",
            duration: d.duration,
            publishTime: d.watchedAt,
            viewCount: 0,
            danmakuCount: 0,
            commentCount: 0,
            authorUID: d.authorUID,
            authorName: d.authorName,
            authorAvatar: "",
            platform: d.platform,
            ugcSeasonID: nil,
            ugcSeasonTitle: nil
        )
        let h = PlaybackHistory(video: item, progressSeconds: d.progressSeconds)
        h.watchedAt = d.watchedAt
        h.lastModifiedAt = d.lastModifiedAt
        h.partCid = d.partCid
        h.partPage = d.partPage
        h.partTitle = d.partTitle
        return h
    }
}

private enum VideoRecordDTOApplier {
    static func make(from d: VideoDTO) -> VideoRecord {
        return VideoRecord(
            aid: d.aid,
            platform: d.platform,
            bvid: d.bvid,
            title: d.title,
            coverURL: d.coverURL,
            webURL: d.webURL,
            duration: d.duration,
            publishTime: d.publishTime,
            viewCount: d.viewCount,
            danmakuCount: d.danmakuCount,
            commentCount: d.commentCount,
            authorUID: d.authorUID,
            authorName: d.authorName,
            authorAvatar: d.authorAvatar,
            firstSeenAt: d.firstSeenAt,
            lastRefreshedAt: d.lastRefreshedAt,
            titleTokens: d.titleTokens,
            authorTokens: d.authorTokens,
            ugcSeasonID: d.ugcSeasonID,
            ugcSeasonTitle: d.ugcSeasonTitle
        ).also { $0.lastModifiedAt = d.lastModifiedAt }
    }
}

/// Swift 单行 tap helper
private extension VideoRecord {
    @discardableResult
    func also(_ block: (VideoRecord) -> Void) -> VideoRecord {
        block(self)
        return self
    }
}
