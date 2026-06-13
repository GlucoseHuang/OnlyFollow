import Foundation
import SwiftData

/// 视频目录条目（SwiftData 持久化）
/// 设计要点：
/// - `aid + platform` 联合唯一：B 站 aid 全局唯一，但保留 platform 字段便于未来扩展到抖音
/// - `firstSeenAt` 用于"是否新增"判定：拉取时新出现的 aid 即视为新视频
/// - `lastRefreshedAt` 用于新鲜度展示 + 搜索时排序参考
/// - `titleTokens` / `authorTokens` 预计算：插入/更新时一次性分词，搜索时只做交集，速度快
@Model
final class VideoRecord {
    /// B 站 aid（其他平台暂无 aid 概念，抖音用 aweme_id 也用同一字段）
    @Attribute(.unique) var aid: Int
    /// 平台标识：当前固定为 "bilibili"
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

    /// 首次入库时间：用于"新增视频"检测
    var firstSeenAt: Date
    /// 最后一次拉取/更新时间：用于显示"X 小时前更新"
    var lastRefreshedAt: Date
    /// 预计算的标题分词（空格分隔）
    /// 搜索时按空格拆分 query，与本字段做集合交集
    var titleTokens: String
    /// 预计算的 UP 主名分词（空格分隔）
    var authorTokens: String

    init(
        aid: Int,
        platform: String,
        bvid: String,
        title: String,
        coverURL: String,
        webURL: String,
        duration: Int,
        publishTime: Date,
        viewCount: Int,
        danmakuCount: Int,
        commentCount: Int,
        authorUID: String,
        authorName: String,
        authorAvatar: String,
        firstSeenAt: Date = .now,
        lastRefreshedAt: Date = .now,
        titleTokens: String = "",
        authorTokens: String = ""
    ) {
        self.aid = aid
        self.platform = platform
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.webURL = webURL
        self.duration = duration
        self.publishTime = publishTime
        self.viewCount = viewCount
        self.danmakuCount = danmakuCount
        self.commentCount = commentCount
        self.authorUID = authorUID
        self.authorName = authorName
        self.authorAvatar = authorAvatar
        self.firstSeenAt = firstSeenAt
        self.lastRefreshedAt = lastRefreshedAt
        self.titleTokens = titleTokens
        self.authorTokens = authorTokens
    }

    /// 转为 VideoItem 给 VideoPlayerView 使用
    /// cid/playURL 由播放页另行拉取详情补齐
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
            platform: platform
        )
    }
}
