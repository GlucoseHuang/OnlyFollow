import Foundation
import UserNotifications

/// 本地通知服务
/// 职责：
/// - 请求通知权限（首次启动时一次性询问）
/// - 发送"新增视频"通知
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var didRequestAuth = false

    private init() {}

    /// 请求通知权限（首次启动调用一次）
    /// - 用户拒绝后再次调用不会弹窗（系统行为）
    func requestAuthorizationIfNeeded() async {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            AppLogger.info("NotificationService: 权限请求 granted=\(granted)")
        } catch {
            AppLogger.error("NotificationService: 权限请求失败 \(error.localizedDescription)")
        }
    }

    /// 发送一条新视频通知
    /// - creator: 发布视频的 UP 主
    /// - video: 新视频
    /// - 一次只发一条；不批量合并（合并会让标题信息丢失）
    func postNewVideoNotification(creator: FollowedCreator, video: VideoItem) async {
        // 检查权限（如果用户拒了，就不发）
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(creator.nickname) 发布了新视频"
        content.body = video.title
        content.sound = .default
        content.userInfo = [
            "aid": video.aid,
            "platform": video.platform,
            "authorUID": creator.uid,
        ]

        // 立即投递（trigger=nil 表示立刻）
        let request = UNNotificationRequest(
            identifier: "new-video-\(creator.uid)-\(video.aid)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            AppLogger.info("NotificationService: 通知已发送 \(creator.nickname) - \(video.title)")
        } catch {
            AppLogger.error("NotificationService: 发送失败 \(error.localizedDescription)")
        }
    }

    /// 批量通知：当一个 UP 主一次发布 ≥4 个新视频时合并成一条
    /// 标题：「UP主名 发布了 N 个新视频」
    /// 正文：最新一个的标题 +「等 N 个新视频」
    func postBatchNewVideoNotification(creator: FollowedCreator, latestVideo: VideoItem, totalNew: Int) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(creator.nickname) 发布了 \(totalNew) 个新视频"
        content.body = "\(latestVideo.title) 等 \(totalNew) 个新视频"
        content.sound = .default
        content.userInfo = [
            "aid": latestVideo.aid,
            "platform": latestVideo.platform,
            "authorUID": creator.uid,
            "batch": true,
            "totalNew": totalNew,
        ]

        // 同一 UP 主的批量通知用固定 identifier，保证短时间内多次刷新只会有一条
        let request = UNNotificationRequest(
            identifier: "new-video-batch-\(creator.uid)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            AppLogger.info("NotificationService: 批量通知已发送 \(creator.nickname) - \(totalNew) 个新视频")
        } catch {
            AppLogger.error("NotificationService: 批量发送失败 \(error.localizedDescription)")
        }
    }
}
