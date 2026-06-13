import Foundation
import SwiftData

@Model
final class FollowedCreator: @unchecked Sendable {
    @Attribute(.unique) var uid: String
    var platform: String
    var nickname: String
    var avatarURL: String
    var addedAt: Date

    // MARK: - 全量历史拉取状态

    /// nil = 还没拉到底；非 nil = 已经拉到第一条视频
    /// 用于：决定是否还需继续拉；显示"X 已完成，Y 补全中"
    var bulkFetchCompletedAt: Date?
    /// 下次要从哪一页继续拉（page 1 已经一次性拉过，存到 VideoRecord 里了）
    /// 默认 2；如果 API 返回 total < page*ps 就直接标记完成
    var bulkFetchNextPage: Int = 2
    /// 该 UP 主的视频总数（API 返回的 count），用于提前终止
    var bulkFetchTotal: Int = 0
    /// 首次同步是否完成过（用于区分「补全历史」vs「新视频通知」）
    /// - false：首次同步完成前不算"新增"，不发通知（避免升级后第一次刷新刷屏）
    /// - true：之后的同步才算增量
    var hasCompletedInitialSync: Bool = false

    init(uid: String, platform: String, nickname: String, avatarURL: String, addedAt: Date = .now) {
        self.uid = uid
        self.platform = platform
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.addedAt = addedAt
    }
}
