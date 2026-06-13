import Foundation
import SwiftData

/// 播放历史记录
/// - 每个 aid 一条，多次播放会更新 progressSeconds + watchedAt（YouTube 风格）
/// - 用途：① 进入视频时按进度续播；② 历史列表展示"几月几日几时几分在看什么"
@Model
final class PlaybackHistory {
    @Attribute(.unique) var aid: Int
    var title: String
    var coverURL: String
    var duration: Int
    var authorUID: String
    var authorName: String
    var platform: String
    /// 上次播放到的位置（秒）。duration=0 表示还没拿到真实时长
    var progressSeconds: Int
    /// 最后观看时间（用于排序）
    var watchedAt: Date

    init(video: VideoItem, progressSeconds: Int = 0) {
        self.aid = video.aid
        self.title = video.title
        self.coverURL = video.coverURL
        self.duration = video.duration
        self.authorUID = video.authorUID
        self.authorName = video.authorName
        self.platform = video.platform
        self.progressSeconds = progressSeconds
        self.watchedAt = Date()
    }

    /// 还原成 VideoItem 喂给播放器；cid 由 fetchVideoDetail 补
    func toVideoItem() -> VideoItem {
        VideoItem(
            id: String(aid),
            aid: aid,
            bvid: "",
            cid: 0,
            title: title,
            coverURL: coverURL,
            playURL: "",
            webURL: "https://www.bilibili.com/video/av\(aid)",
            duration: duration,
            publishTime: watchedAt,
            viewCount: 0,
            danmakuCount: 0,
            commentCount: 0,
            authorUID: authorUID,
            authorName: authorName,
            authorAvatar: "",
            platform: platform
        )
    }
}
