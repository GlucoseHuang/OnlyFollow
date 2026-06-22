import Foundation
import SwiftData

/// 本地 SwiftData → SyncSnapshot（导出）
///
/// 调用方：SyncCoordinator 在 debounce 触发后 / 立即同步时调用
/// 一次性把所有记录读到内存、转 DTO、返回；CPU bound 操作
/// 不负责写文件、不负责编码（那是 SyncCodec / SyncStorage）
@MainActor
enum SyncExporter {
    /// 导出整库快照
    static func exportAll(from context: ModelContext) -> SyncSnapshot {
        let creators = (try? context.fetch(FetchDescriptor<FollowedCreator>())) ?? []
        let favorites = (try? context.fetch(FetchDescriptor<FavoriteVideo>())) ?? []
        let playlist = (try? context.fetch(FetchDescriptor<PlaylistItem>())) ?? []
        let history = (try? context.fetch(FetchDescriptor<PlaybackHistory>())) ?? []
        let videos = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        let liveHistory = (try? context.fetch(FetchDescriptor<LiveHistory>())) ?? []

        return SyncSnapshot(
            schemaVersion: SyncSnapshot.currentSchemaVersion,
            deviceID: SyncStorage.shared.deviceID,
            generatedAt: Date(),
            creators: creators.map(toDTO),
            favorites: favorites.map(toDTO),
            playlist: playlist.map(toDTO),
            history: history.map(toDTO),
            videos: videos.map(toDTO),
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
        VideoDTO(
            aid: v.aid,
            platform: v.platform,
            bvid: v.bvid,
            title: v.title,
            coverURL: v.coverURL,
            webURL: v.webURL,
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
            titleTokens: v.titleTokens,
            authorTokens: v.authorTokens,
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
