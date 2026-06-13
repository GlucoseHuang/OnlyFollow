import Foundation
import SwiftData

/// 视频同步编排器
/// 职责：把"拉 API → 写 VideoRecord → 检测新视频 → 通知"这条流水线串起来
/// 设计：
/// - 所有方法都接收 `ModelContext` 入参（不缓存 context，避免线程歧义）
/// - 调用方负责在合适的时机触发：scenePhase active / 下拉刷新 / BGAppRefreshTask
/// - 限流交给 BilibiliAPIService 内部处理（3s + 指数退避）
@MainActor
enum VideoSyncService {
    /// 单个 UP 主 bulk fetch 最多拉的页数
    /// - 30 videos/页 × 350 页 = 10,500 videos 上限
    /// - 防止 B 站接口异常返回超大 count 导致死循环
    static let bulkFetchMaxPages = 350
    /// 增量刷新的结果摘要
    struct IncrementalRefreshResult {
        let refreshed: Int
        let notified: Int
        let total: Int
        /// 命中过限流（不再继续拉后面的）
        var hitRateLimit: Bool = false
        /// 命中过风控（不再继续拉后面的）
        var hitAntiCrawler: Bool = false
        var anyFailure: Bool { hitRateLimit || hitAntiCrawler }
    }

    /// 增量刷新：每个 UP 主拉首页（30 条）
    /// - 已存在 aid：更新 viewCount 等字段（顺带"刷播放量"）
    /// - 新增 aid：入库 + 发本地通知
    /// - 直播状态：每次顺手拉一次（userInfo 接口返回 live_room）
    /// - 返回：被刷新的 creator 数 + 通知数 + 是否命中限流 / 风控
    @discardableResult
    static func performIncrementalRefresh(creators: [FollowedCreator], in context: ModelContext) async -> IncrementalRefreshResult {
        guard !creators.isEmpty else { return IncrementalRefreshResult(refreshed: 0, notified: 0, total: 0) }
        let api = BilibiliAPIService.shared
        var refreshed = 0
        var totalNotified = 0
        var hitRateLimit = false
        var hitAntiCrawler = false
        var shouldStop = false

        for creator in creators {
            if shouldStop { break }
            do {
                // 1) 直播状态（每次刷新顺带拉一次，便宜）
                if let info = try? await api.fetchUserInfo(mid: creator.uid), let live = info.liveRoom {
                    let room = LiveRoom(
                        id: "\(live.roomid)",
                        roomID: "\(live.roomid)",
                        title: live.title,
                        coverURL: ensureHTTPS(live.cover),
                        streamURL: live.url ?? "",
                        viewerCount: 0,
                        authorUID: creator.uid,
                        authorName: creator.nickname,
                        authorAvatar: ensureHTTPS(creator.avatarURL),
                        platform: "bilibili",
                        isLive: live.isLiving
                    )
                    VideoCache.shared.setLiveRoom(room, for: creator.uid)
                }

                // 2) 拉首页
                let result = try await api.fetchUserVideosWithPageInfo(mid: creator.uid, page: 1, pageSize: 30)
                let videos = result.videos
                let pageInfo = result.pageInfo

                // 3) upsert；返回的新 aid 集合 = 新视频
                let newlyAdded = VideoCatalog.upsert(videos, into: context)

                // 4) 写批量拉取状态
                // - total 变了且原本已完成 → 页码下移失效，nextPage 重置为 2 重拉
                // - total <= ps → 单页就到末页，标完成
                // - 都没变 → 不写库
                let totalChanged = creator.bulkFetchTotal != pageInfo.count
                let isSinglePage = pageInfo.count <= pageInfo.ps
                let wasComplete = creator.bulkFetchCompletedAt != nil
                if totalChanged || isSinglePage {
                    VideoCatalog.updateBulkFetchState(
                        for: creator,
                        completedAt: isSinglePage ? .some(.now) : .some(nil),
                        nextPage: (totalChanged && wasComplete) ? 2 : nil,
                        total: totalChanged ? pageInfo.count : nil,
                        in: context
                    )
                }

                // 5) 把首页结果也灌一份到 VideoCache（首页展示仍依赖它）
                VideoCache.shared.setVideos(videos, for: creator.uid)

                // 6) 新视频 → 本地通知
                // - 1-3 条新视频：每条单独发（用户能看到具体标题）
                // - 4+ 条新视频：合并成一条汇总（避免锁屏被刷屏）
                // - 首次同步（hasCompletedInitialSync == false）：不发通知，避免升级后一次性刷屏
                if !newlyAdded.isEmpty && creator.hasCompletedInitialSync {
                    // 按视频原始顺序（API 返回的顺序 = 发布时间倒序）排序 aids
                    let orderedAids = videos.map(\.aid)
                    let sortedNewlyAdded = orderedAids.filter { newlyAdded.contains($0) }
                    if sortedNewlyAdded.count <= 3 {
                        for aid in sortedNewlyAdded {
                            if let v = videos.first(where: { $0.aid == aid }) {
                                await NotificationService.shared.postNewVideoNotification(creator: creator, video: v)
                                totalNotified += 1
                            }
                        }
                    } else {
                        if let latestAid = sortedNewlyAdded.first,
                           let latest = videos.first(where: { $0.aid == latestAid }) {
                            await NotificationService.shared.postBatchNewVideoNotification(
                                creator: creator,
                                latestVideo: latest,
                                totalNew: sortedNewlyAdded.count
                            )
                            totalNotified += 1
                        }
                    }
                }

                refreshed += 1
                // 标记首次同步完成（只设置一次，之后的通知逻辑会发新视频通知）
                if !creator.hasCompletedInitialSync {
                    creator.hasCompletedInitialSync = true
                    try? context.save()
                }
            } catch APIError.rateLimited {
                AppLogger.error("VideoSyncService: 限流，停止增量刷新：\(creator.nickname)")
                hitRateLimit = true
                shouldStop = true
            } catch APIError.antiCrawler {
                AppLogger.error("VideoSyncService: 风控，停止增量刷新：\(creator.nickname)")
                hitAntiCrawler = true
                shouldStop = true
            } catch {
                AppLogger.error("VideoSyncService: 增量刷新失败 \(creator.nickname): \(error.localizedDescription)")
            }
        }

        AppLogger.info("VideoSyncService: 增量刷新完成 \(refreshed)/\(creators.count), 通知 \(totalNotified) 条")
        return IncrementalRefreshResult(
            refreshed: refreshed,
            notified: totalNotified,
            total: creators.count,
            hitRateLimit: hitRateLimit,
            hitAntiCrawler: hitAntiCrawler
        )
    }

    /// 全量历史拉取 — 单页
    /// - 从 creator.bulkFetchNextPage 开始拉一页（30 条）
    /// - 写入 VideoRecord
    /// - 更新 cursor / total / completedAt
    /// - 返回是否还有下一页
    @discardableResult
    static func continueBulkFetch(creator: FollowedCreator, in context: ModelContext) async -> Bool {
        let state = VideoCatalog.bulkFetchState(for: creator)
        if state.isCompleted {
            return false
        }
        let nextPage = state.nextPage
        let api = BilibiliAPIService.shared
        do {
            let result = try await api.fetchUserVideosWithPageInfo(mid: creator.uid, page: nextPage, pageSize: 30)
            let videos = result.videos
            let pageInfo = result.pageInfo

            // 写入数据库（VideoRecord，给搜索用）
            _ = VideoCatalog.upsert(videos, into: context)
            // 同时把这一页追加到 VideoCache（详情页用），让 bulk fetch 的进度在 CreatorDetailView 里可见
            VideoCache.shared.appendVideos(videos, for: creator.uid)

            // 计算是否到底
            let total = pageInfo.count
            let ps = pageInfo.ps
            let pagesFetched = nextPage  // 已经完成 1..nextPage 这些页
            let totalPages = min((total + ps - 1) / ps, bulkFetchMaxPages)
            // 防御：API 返回的 videos.count < ps 时也视为本页结束
            let isCompleted = pagesFetched >= totalPages || videos.isEmpty || videos.count < ps

            VideoCatalog.updateBulkFetchState(
                for: creator,
                completedAt: isCompleted ? .some(.now) : .some(nil),
                nextPage: nextPage + 1,
                total: total,
                in: context
            )

            AppLogger.info("VideoSyncService: bulk fetch \(creator.nickname) page=\(nextPage)/\(totalPages), returned=\(videos.count), completed=\(isCompleted)")
            return !isCompleted
        } catch APIError.rateLimited {
            AppLogger.error("VideoSyncService: bulk fetch 限流，暂停 \(creator.nickname)")
            return true  // 还有下一页，但本轮停了
        } catch APIError.antiCrawler {
            AppLogger.error("VideoSyncService: bulk fetch 风控，暂停 \(creator.nickname)")
            return true
        } catch {
            AppLogger.error("VideoSyncService: bulk fetch 失败 \(creator.nickname): \(error.localizedDescription)")
            return true
        }
    }

    /// 机会式批量拉取 — 单页（在 App 前台时调用）
    /// 策略：找一个未完成的 creator，拉一页；返回还剩多少 creator 没拉完
    /// - 一次只拉一个 creator 的一页（30 条），避免长时间霸占 API
    /// - 调用方可以循环调用直到返回 0（所有 creator 都拉到底）
    /// - 内置 3s 间隔（API service 自身的限流会兜底）
    @discardableResult
    static func opportunisticBulkFetchStep(in context: ModelContext) async -> Int {
        let predicate = #Predicate<FollowedCreator> { $0.bulkFetchCompletedAt == nil && $0.platform == "bilibili" }
        let pending = (try? context.fetch(FetchDescriptor<FollowedCreator>(predicate: predicate))) ?? []
        guard let next = pending.first else { return 0 }
        let hasMore = await continueBulkFetch(creator: next, in: context)
        return hasMore ? pending.count : pending.count - 1
    }

    /// 机会式批量拉取 — 多页循环
    /// - 在 foreground 触发时调用，一次性推进 N 页（约 3.5s/页，所以 10 页 ≈ 35s）
    /// - 命中 -799 限流会自动停（continueBulkFetch 内部处理）
    /// - 支持 Task 取消：用户切后台时取消循环，不会在后台瞎跑
    /// - 返回实际推进的页数
    @discardableResult
    static func opportunisticBulkFetchLoop(in context: ModelContext, maxPages: Int = 10) async -> Int {
        var processed = 0
        for _ in 0..<maxPages {
            if Task.isCancelled { break }
            let remaining = await opportunisticBulkFetchStep(in: context)
            processed += 1
            if remaining == 0 { break }  // 所有 UP 主都拉完了
        }
        if processed > 0 {
            AppLogger.info("VideoSyncService: bulk fetch loop 跑了 \(processed) 页")
        }
        return processed
    }

    /// 把所有已 follow 但还没开始 bulk fetch 的 creator 状态初始化
    /// - bulkFetchNextPage = 2（page 1 由 incremental 拿）
    /// - 应用启动时调用一次即可
    static func ensureBulkFetchInitialized(creators: [FollowedCreator], in context: ModelContext) {
        for c in creators where c.platform == "bilibili" {
            // bulkFetchNextPage 默认是 2（首次 init 时的值）；如果发现是 1（异常状态），也修正
            if c.bulkFetchNextPage < 2 {
                c.bulkFetchNextPage = 2
            }
            // bulkFetchTotal 在第一次 incremental 之前是 0，正常
        }
        try? context.save()
    }
}
