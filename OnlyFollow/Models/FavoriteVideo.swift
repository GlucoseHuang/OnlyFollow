import Foundation
import SwiftData

/// 用户收藏的视频（本地存储，不与 B 站账号同步）
@Model
final class FavoriteVideo {
    /// aid 作为主键
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
    var addedAt: Date

    /// 多设备同步用的最后修改时间。收藏一旦加进去几乎不会变，所以基本就是 addedAt。
    var lastModifiedAt: Date = Date()

    init(video: VideoItem) {
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
