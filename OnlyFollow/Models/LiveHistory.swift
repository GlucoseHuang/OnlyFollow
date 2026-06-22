import Foundation
import SwiftData

/// 直播观看历史（与 PlaybackHistory 对齐的轻量模型）
/// - 设计要点：
///   - `roomID` 作为唯一键（同一房间多次进入只更新 `watchedAt`，不追加新行）
///   - 没有 progress 概念（直播是流式的，没有"看到 1:23"）
///   - 复用 PlaybackHistory 的 `lastModifiedAt` 同步语义
///   - authorUID/authorName/authorAvatar 在打开直播间时从 LiveRoom 写入，
///     之后从历史列表点击重新进入时也能正确显示 UP 主信息
@Model
final class LiveHistory {
    /// B 站 room_id（其他平台未来扩展时用同样的字段存 room_id）
    @Attribute(.unique) var roomID: Int
    var title: String
    var coverURL: String
    var authorUID: String
    var authorName: String
    var authorAvatar: String
    var platform: String
    /// 最后一次进入时间（用于排序 + 历史列表展示）
    var watchedAt: Date

    /// 多设备同步用的最后修改时间；merge 时较新的覆盖较旧的。
    var lastModifiedAt: Date = Date()

    init(
        roomID: Int,
        title: String,
        coverURL: String,
        authorUID: String,
        authorName: String,
        authorAvatar: String,
        platform: String,
        watchedAt: Date = .now
    ) {
        self.roomID = roomID
        self.title = title
        self.coverURL = coverURL
        self.authorUID = authorUID
        self.authorName = authorName
        self.authorAvatar = authorAvatar
        self.platform = platform
        self.watchedAt = watchedAt
    }

    /// 还原成 LiveRoom 喂给播放器；streamURL 为空（进入时再 fetchLiveStreamURL 拿）
    /// - isLive 暂时设为 true（从历史点进去时再 fetchLiveRoom 拿真实状态）
    /// - viewerCount = 0（同上）
    func toLiveRoom() -> LiveRoom {
        LiveRoom(
            id: "\(roomID)",
            roomID: "\(roomID)",
            title: title,
            coverURL: coverURL,
            streamURL: "",
            viewerCount: 0,
            authorUID: authorUID,
            authorName: authorName,
            authorAvatar: authorAvatar,
            platform: platform,
            isLive: true
        )
    }
}
