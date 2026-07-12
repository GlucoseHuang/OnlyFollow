import Foundation
import SwiftData

/// 取消关注的统一入口
///
/// 职责:
/// 1. 删 FollowedCreator 实体
/// 2. 删 VideoRecord 中 authorUID 匹配的所有记录(本机缓存 + 同步上云)
/// 3. 清 VideoCache 中该 UP 主的内存/磁盘缓存
/// 4. **保留** FavoriteVideo / PlaylistItem / PlaybackHistory / LiveHistory 中的条目
///    - 播放不依赖 VideoRecord(走 fetchVideoDetail + fetchPlayURL 实时拉),保留条目可继续播放
/// 5. save + kickUpload,云端 snapshot 自动跟着瘦身(SyncExporter 会按 creators 过滤)
///
/// 设计要点:
/// - 所有删除动作走一个入口,避免 CreatorDetailView / FollowManageView 等地方遗漏清理
/// - 二次确认弹窗用 countRetained 拿数字,展示给用户看
@MainActor
enum UnfollowService {

    /// "如果现在取消关注这个 UP 主,会保留多少个可播放视频 + 删除多少个缓存视频"
    /// - 用于二次确认弹窗
    struct RetainedCounts: Equatable {
        let favorites: Int
        let playlist: Int
        let history: Int
        let liveHistory: Int
        /// 将被删除的 VideoRecord 数量(本机缓存)
        let videosToPurge: Int
        var hasRetained: Bool { favorites + playlist + history + liveHistory > 0 }
    }

    /// 统计 + 一次 SwiftData 查询(用 fetchCount,比 fetch 全量省内存)
    static func countRetained(uid: String, in context: ModelContext) -> RetainedCounts {
        let videoPredicate = #Predicate<VideoRecord> { $0.authorUID == uid }
        let videosToPurge = (try? context.fetchCount(FetchDescriptor<VideoRecord>(predicate: videoPredicate))) ?? 0

        let favPredicate = #Predicate<FavoriteVideo> { $0.authorUID == uid }
        let favorites = (try? context.fetchCount(FetchDescriptor<FavoriteVideo>(predicate: favPredicate))) ?? 0

        let plPredicate = #Predicate<PlaylistItem> { $0.authorUID == uid }
        let playlist = (try? context.fetchCount(FetchDescriptor<PlaylistItem>(predicate: plPredicate))) ?? 0

        let histPredicate = #Predicate<PlaybackHistory> { $0.authorUID == uid }
        let history = (try? context.fetchCount(FetchDescriptor<PlaybackHistory>(predicate: histPredicate))) ?? 0

        let livePredicate = #Predicate<LiveHistory> { $0.authorUID == uid }
        let liveHistory = (try? context.fetchCount(FetchDescriptor<LiveHistory>(predicate: livePredicate))) ?? 0

        return RetainedCounts(
            favorites: favorites,
            playlist: playlist,
            history: history,
            liveHistory: liveHistory,
            videosToPurge: videosToPurge
        )
    }

    /// 给定 counts,生成弹窗文案
    /// - lines 数组 join 成多行,确认弹窗里展示
    static func dialogMessage(for counts: RetainedCounts) -> String {
        var lines: [String] = []
        if counts.videosToPurge > 0 {
            lines.append("将删除 \(counts.videosToPurge) 个缓存视频")
        }
        var retained: [String] = []
        if counts.favorites > 0 { retained.append("\(counts.favorites) 个收藏") }
        if counts.playlist > 0 { retained.append("\(counts.playlist) 个播放列表") }
        if counts.history > 0 { retained.append("\(counts.history) 个历史") }
        if counts.liveHistory > 0 { retained.append("\(counts.liveHistory) 个直播历史") }
        if !retained.isEmpty {
            lines.append("保留 \(retained.joined(separator: "、"))中的视频,仍可正常播放")
        }
        if lines.isEmpty {
            return "将从首页移除该 UP 主。"
        }
        return lines.joined(separator: "\n") + "。"
    }

    /// 取消关注 + 清理该 UP 主的所有缓存数据
    /// - 删:FollowedCreator + VideoRecord(按 authorUID)
    /// - 保留:FavoriteVideo / PlaylistItem / PlaybackHistory / LiveHistory
    /// - 内存缓存:VideoCache.invalidate
    /// - 同步:save 后调 kickUpload,SyncExporter 自动按 creators 过滤,远端 snapshot 跟着瘦身
    /// - 多设备:其他设备 sync 时,SyncMerger.purgeOrphanedVideos 会把残留的 VideoRecord 也清掉
    static func unfollow(_ creator: FollowedCreator, in context: ModelContext) {
        // 先把字段值拷出来,避免 delete 后访问属性出问题
        let uid = creator.uid
        let nickname = creator.nickname
        AppLogger.info("UnfollowService: unfollow uid=\(uid) name=\(nickname)")

        // 1. 删 VideoRecord(必须在删 FollowedCreator 之前查,删了之后就拿不到 authorUID 了)
        let videoPredicate = #Predicate<VideoRecord> { $0.authorUID == uid }
        let videosToDelete = (try? context.fetch(FetchDescriptor<VideoRecord>(predicate: videoPredicate))) ?? []
        for v in videosToDelete {
            context.delete(v)
        }

        // 2. 删 FollowedCreator
        context.delete(creator)

        // 3. 内存 + 磁盘缓存(VideoCache 是 @MainActor,这里也是 @MainActor,可以直接调)
        VideoCache.shared.invalidate(uid: uid)

        // 4. save + kickUpload → SyncExporter 按 creators 过滤 → 上传瘦身后的 snapshot
        context.saveAndKickSync()

        AppLogger.info("UnfollowService: unfollow done, removed \(videosToDelete.count) VideoRecord(s) for uid=\(uid)")
    }
}
