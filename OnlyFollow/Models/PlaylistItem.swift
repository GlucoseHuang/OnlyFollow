import Foundation
import SwiftData

/// 播放列表项（本地存储）
/// 顺序由 `order` 字段控制（越小越靠前）
@Model
final class PlaylistItem {
    @Attribute(.unique) var aid: Int
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
    /// 播放顺序，越小越靠前
    var order: Int
    var addedAt: Date

    /// 多设备同步用的最后修改时间。order 变动时需要刷新这个值（后写获胜）。
    var lastModifiedAt: Date = Date()

    init(video: VideoItem, order: Int) {
        self.aid = video.aid
        self.bvid = video.bvid
        self.title = video.title
        self.coverURL = video.coverURL
        self.duration = video.duration
        self.publishTime = video.publishTime
        self.viewCount = video.viewCount
        self.danmakuCount = video.danmakuCount
        self.commentCount = video.commentCount
        self.authorUID = video.authorUID
        self.authorName = video.authorName
        self.authorAvatar = video.authorAvatar
        self.platform = video.platform
        self.order = order
        self.addedAt = Date()
    }

    /// 还原为 VideoItem 用于播放器
    func toVideoItem() -> VideoItem {
        VideoItem(
            id: String(aid),
            aid: aid,
            bvid: bvid,
            cid: 0,  // cid 需要时再 fetch
            title: title,
            coverURL: coverURL,
            playURL: "",
            webURL: "https://www.bilibili.com/video/av\(aid)",
            duration: duration,
            publishTime: publishTime,
            viewCount: viewCount,
            danmakuCount: danmakuCount,
            commentCount: commentCount,
            authorUID: authorUID,
            authorName: authorName,
            authorAvatar: authorAvatar,
            platform: platform,
            ugcSeasonID: nil,
            ugcSeasonTitle: nil
        )
    }
}
