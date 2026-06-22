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
    /// 最后观看的分 P 的 cid(0 = 单 P 视频或还没记录)
    /// - 续播时用来定位到正确的分 P,而不是每次都从 P1 开始
    /// - 同一个 BV 号下切换分 P 时,只更新这条字段,不新建历史条目
    var partCid: Int = 0
    /// 最后观看的分 P 在 `pages[]` 里的 1-based 页码(0 表示单 P 视频或还没记录)
    /// 列表展示用,避免每次都要拉 fetchVideoDetail 才能算页码
    var partPage: Int = 0
    /// 最后观看的分 P 的标题(可空)。列表展示用
    var partTitle: String = ""
    /// 最后观看时间（用于排序）
    var watchedAt: Date

    /// 多设备同步用的最后修改时间。merge 时较新的覆盖较旧的；同步后另一台设备接着从最新进度播放。
    var lastModifiedAt: Date = Date()

    init(video: VideoItem, progressSeconds: Int = 0, partCid: Int = 0, partPage: Int = 0, partTitle: String = "") {
        self.aid = video.aid
        self.title = video.title
        self.coverURL = video.coverURL
        self.duration = video.duration
        self.authorUID = video.authorUID
        self.authorName = video.authorName
        self.platform = video.platform
        self.progressSeconds = progressSeconds
        self.partCid = partCid
        self.partPage = partPage
        self.partTitle = partTitle
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
            platform: platform,
            ugcSeasonID: nil,
            ugcSeasonTitle: nil
        )
    }
}
