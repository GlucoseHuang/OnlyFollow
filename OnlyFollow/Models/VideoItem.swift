import Foundation

struct VideoItem: Identifiable, Codable, Sendable, Equatable {
    let id: String
    /// 视频 AV 号（用于详情 / 播放 / 评论）
    let aid: Int
    /// 视频 BV 号
    let bvid: String
    /// 视频 cid（播放地址 + 弹幕 XML 都靠这个）
    let cid: Int
    let title: String
    let coverURL: String
    /// 实际 CDN 播放 URL（带 ?xxx 鉴权参数），由 fetchVideoPlayURL 获取
    let playURL: String
    /// UP 主投稿页 URL（fallback）
    let webURL: String
    let duration: Int
    let publishTime: Date
    let viewCount: Int
    let danmakuCount: Int
    let commentCount: Int
    let authorUID: String
    let authorName: String
    let authorAvatar: String
    let platform: String
}
