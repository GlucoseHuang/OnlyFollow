import Foundation
import SwiftData

/// 本地 SwiftData → SyncSnapshot（导出）
///
/// 调用方：SyncCoordinator 在 debounce 触发后 / 立即同步时调用
/// 一次性把所有记录读到内存、转 DTO、返回；CPU bound 操作
/// 不负责写文件、不负责编码（那是 SyncCodec / SyncStorage）
///
/// ⚠️ 必须保持 nonisolated（不要加 @MainActor）
/// - 调用方从 Task.detached 调, 6 次 context.fetch 在背景 context 上跑
/// - 如果加 @MainActor, await 会强制跳回主线程, 2200+ 条记录 = 主线程卡 100-500ms
/// - 历史上这个 bug 让用户播放视频时 ~5s 卡一次, 表现为"弹幕突然跳几厘米"
enum SyncExporter {
    /// 导出整库快照
    static func exportAll(from context: ModelContext) -> SyncSnapshot {
        let creators = (try? context.fetch(FetchDescriptor<FollowedCreator>())) ?? []
        let favorites = (try? context.fetch(FetchDescriptor<FavoriteVideo>())) ?? []
        let playlist = (try? context.fetch(FetchDescriptor<PlaylistItem>())) ?? []
        let history = (try? context.fetch(FetchDescriptor<PlaybackHistory>())) ?? []
        let videos = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        let liveHistory = (try? context.fetch(FetchDescriptor<LiveHistory>())) ?? []

        // 过滤掉"作者已不在关注列表中"的 VideoRecord
        // - 取消关注时本机已经删了 VideoRecord + FollowedCreator,这里再过滤一次是双保险
        // - 多设备场景: A 设备 unfollow → B 设备 pull 后,merge 还没把 creators 更新,
        //   这时 B 上传 snapshot 仍可能带着已不关注的 UP 的视频 → 过滤掉,远端 snapshot 跟着瘦
        let followedUids = Set(creators.map(\.uid))
        let filteredVideos = videos.filter { followedUids.contains($0.authorUID) }
        let purgedCount = videos.count - filteredVideos.count
        if purgedCount > 0 {
            AppLogger.info("SyncExporter: filtered \(purgedCount) VideoRecord(s) whose author is not in followed creators")
        }

        return SyncSnapshot(
            schemaVersion: SyncSnapshot.currentSchemaVersion,
            deviceID: SyncStorage.shared.deviceID,
            generatedAt: Date(),
            creators: creators.map(toDTO),
            favorites: favorites.map(toDTO),
            playlist: playlist.map(toDTO),
            history: history.map(toDTO),
            videos: filteredVideos.map(toDTO),
            liveHistory: liveHistory.map(toDTO)
        )
    }

    // MARK: - @Model → DTO

    private static func toDTO(_ c: FollowedCreator) -> CreatorDTO {
        CreatorDTO(
            uid: c.uid,
            platform: c.platform,
            nickname: c.nickname,
            avatarURL: c.avatarURL,
            addedAt: c.addedAt,
            bulkFetchCompletedAt: c.bulkFetchCompletedAt,
            bulkFetchNextPage: c.bulkFetchNextPage,
            bulkFetchTotal: c.bulkFetchTotal,
            hasCompletedInitialSync: c.hasCompletedInitialSync,
            lastModifiedAt: c.lastModifiedAt
        )
    }

    private static func toDTO(_ f: FavoriteVideo) -> FavoriteDTO {
        FavoriteDTO(
            aid: f.aid,
            bvid: f.bvid,
            title: f.title,
            coverURL: f.coverURL,
            duration: f.duration,
            publishTime: f.publishTime,
            viewCount: f.viewCount,
            danmakuCount: f.danmakuCount,
            commentCount: f.commentCount,
            authorUID: f.authorUID,
            authorName: f.authorName,
            authorAvatar: f.authorAvatar,
            platform: f.platform,
            addedAt: f.addedAt,
            lastModifiedAt: f.lastModifiedAt
        )
    }

    private static func toDTO(_ p: PlaylistItem) -> PlaylistDTO {
        PlaylistDTO(
            aid: p.aid,
            bvid: p.bvid,
            title: p.title,
            coverURL: p.coverURL,
            duration: p.duration,
            publishTime: p.publishTime,
            viewCount: p.viewCount,
            danmakuCount: p.danmakuCount,
            commentCount: p.commentCount,
            authorUID: p.authorUID,
            authorName: p.authorName,
            authorAvatar: p.authorAvatar,
            platform: p.platform,
            order: p.order,
            addedAt: p.addedAt,
            lastModifiedAt: p.lastModifiedAt
        )
    }

    private static func toDTO(_ h: PlaybackHistory) -> HistoryDTO {
        HistoryDTO(
            aid: h.aid,
            title: h.title,
            coverURL: h.coverURL,
            duration: h.duration,
            authorUID: h.authorUID,
            authorName: h.authorName,
            platform: h.platform,
            progressSeconds: h.progressSeconds,
            partCid: h.partCid,
            partPage: h.partPage,
            partTitle: h.partTitle,
            watchedAt: h.watchedAt,
            lastModifiedAt: h.lastModifiedAt
        )
    }

    private static func toDTO(_ v: VideoRecord) -> VideoDTO {
        // webURL / titleTokens / authorTokens 不再写入 DTO(本机可算/可拼)
        // - 老 snapshot 解码时这三个字段是可选,本字段不传时会被 Codable 跳过
        VideoDTO(
            aid: v.aid,
            platform: v.platform,
            bvid: v.bvid,
            title: v.title,
            coverURL: v.coverURL,
            webURL: nil,
            duration: v.duration,
            publishTime: v.publishTime,
            viewCount: v.viewCount,
            danmakuCount: v.danmakuCount,
            commentCount: v.commentCount,
            authorUID: v.authorUID,
            authorName: v.authorName,
            authorAvatar: v.authorAvatar,
            firstSeenAt: v.firstSeenAt,
            lastRefreshedAt: v.lastRefreshedAt,
            titleTokens: nil,
            authorTokens: nil,
            ugcSeasonID: v.ugcSeasonID,
            ugcSeasonTitle: v.ugcSeasonTitle,
            lastModifiedAt: v.lastModifiedAt
        )
    }

    private static func toDTO(_ h: LiveHistory) -> LiveHistoryDTO {
        LiveHistoryDTO(
            roomID: h.roomID,
            title: h.title,
            coverURL: h.coverURL,
            authorUID: h.authorUID,
            authorName: h.authorName,
            authorAvatar: h.authorAvatar,
            platform: h.platform,
            watchedAt: h.watchedAt,
            lastModifiedAt: h.lastModifiedAt
        )
    }
}
