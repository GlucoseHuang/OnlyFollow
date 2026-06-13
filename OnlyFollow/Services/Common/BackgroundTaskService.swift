import Foundation
import BackgroundTasks
import SwiftData

/// 后台任务调度
/// - 注册 BGAppRefreshTask：在系统认为合适的时机帮我们跑一次"增量刷新"
/// - handler 必须 setTaskCompleted，否则系统会记我们超时
/// - handler 内还要重新提交下一次（系统不会自动续）
@MainActor
enum BackgroundTaskService {
    static let refreshIdentifier = "com.personal.OnlyFollow.refresh"

    /// 在 App 启动时调用一次（OnlyFollowApp.init 之前注册）
    /// 必须在 didFinishLaunching 之前调用，否则 BGTaskScheduler.shared.register 会失败
    static func register(modelContainer: ModelContainer) {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier,
            using: nil
        ) { task in
            // BGTaskScheduler 的 launch handler 在非主线程被调用；
            // 用 Task { @MainActor in ... } 包一层确保我们跑到主线程上
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                BackgroundTaskService.handleIncrementalRefresh(task: appRefreshTask, modelContainer: modelContainer)
            }
        }
        AppLogger.info("BackgroundTaskService: register \(refreshIdentifier) -> \(registered)")
    }

    /// 安排下一次后台刷新（系统在 earliestBeginDate 之后才会考虑拉起）
    /// - 间隔建议 ≥ 1 小时（系统实际可能更久，受用户充电/网络/系统压力影响）
    static func scheduleIncrementalRefresh(earliestAfter seconds: TimeInterval = 3600 * 4) {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.info("BackgroundTaskService: scheduled next refresh at \(request.earliestBeginDate?.description ?? "?")")
        } catch {
            AppLogger.error("BackgroundTaskService: schedule failed \(error.localizedDescription)")
        }
    }

    /// 后台刷新 handler
    /// - 创建临时 ModelContext（避免跨线程持有 view context）
    /// - 跑一遍 incremental refresh
    /// - 必须 setTaskCompleted，否则系统会标记失败
    private static func handleIncrementalRefresh(task: BGAppRefreshTask, modelContainer: ModelContainer) {
        // 安排下一次（不管这次成功失败都安排）
        scheduleIncrementalRefresh()

        // 给 BGTask 一个过期时间（系统通常给 30s）
        task.expirationHandler = {
            Task { @MainActor in
                AppLogger.error("BackgroundTaskService: handler expired")
            }
        }

        Task { @MainActor in
            let context = ModelContext(modelContainer)
            // 拉所有 B 站 creator 做增量刷新
            let bilibiliCreators = (try? context.fetch(
                FetchDescriptor<FollowedCreator>(
                    predicate: #Predicate { $0.platform == "bilibili" }
                )
            )) ?? []
            let result = await VideoSyncService.performIncrementalRefresh(creators: bilibiliCreators, in: context)
            AppLogger.info("BackgroundTaskService: incremental refresh done, refreshed=\(result.refreshed), notified=\(result.notified)")
            task.setTaskCompleted(success: result.refreshed > 0)
        }
    }
}
