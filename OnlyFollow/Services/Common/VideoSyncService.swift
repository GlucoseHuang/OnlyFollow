import Foundation
import SwiftData

/// 在后台 ModelContext 上跑一段 SwiftData 工作,避免主线程被 save 阻塞
/// - 原因:iOS 17/18 SwiftData save 已知会阻塞主线程(Apple 自家论坛也建议挪到 detached Task)
/// - 调用方传入一段闭包,闭包内可以放心 insert / fetch / save,SwiftData 会在后台 save 完后
///   自动 propagate 到主 context(@Query 视图会自动刷新)
@MainActor
enum VideoSyncBackground {
    static func run<T: Sendable>(_ work: @escaping @Sendable (ModelContext) throws -> T) async throws -> T {
        let container = OnlyFollowApp.sharedContainer
        return try await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            return try work(bgContext)
        }.value
    }
}

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
        var refreshed = 0
        var totalNotified = 0
        var hitRateLimit = false
        var hitAntiCrawler = false
        var shouldStop = false

        for creator in creators {
            if shouldStop { break }
            switch creator.platform {
            case "bilibili":
                if await refreshOneBilibili(creator: creator, in: context, totalNotified: &totalNotified) {
                    refreshed += 1
                } else {
                    shouldStop = true
                    hitRateLimit = true
                }
            case "douyin":
                if await refreshOneDouyin(creator: creator, in: context, totalNotified: &totalNotified) {
                    refreshed += 1
                } else {
                    shouldStop = true
                    hitRateLimit = true
                }
            default:
                break
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

    /// B 站增量刷新单个 creator。返回 true=成功刷新,false=失败(限流/风控)
    private static func refreshOneBilibili(creator: FollowedCreator, in context: ModelContext, totalNotified: inout Int) async -> Bool {
        let api = BilibiliAPIService.shared
        do {
            // 1) 直播状态
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

            // 3) upsert
            let newlyAdded = try await VideoSyncBackground.run { bgContext in
                VideoCatalog.upsert(videos, into: bgContext)
            }

            // 4) 批量拉取状态
            let totalChanged = creator.bulkFetchTotal != pageInfo.count
            let isSinglePage = pageInfo.count <= pageInfo.ps
            let wasComplete = creator.bulkFetchCompletedAt != nil
            // DEBUG: 验证 Bug 1 - 状态机决策
            AppLogger.info("DEBUG refreshOneBilibili: uid=\(creator.uid) name=\(creator.nickname) pageInfo.count=\(pageInfo.count) pageInfo.ps=\(pageInfo.ps) totalChanged=\(totalChanged) isSinglePage=\(isSinglePage) wasComplete=\(wasComplete) [before: total=\(creator.bulkFetchTotal) completedAt=\(creator.bulkFetchCompletedAt?.description ?? "nil")]")
            if totalChanged || isSinglePage {
                VideoCatalog.updateBulkFetchState(
                    for: creator,
                    completedAt: isSinglePage ? .some(.now) : .some(nil),
                    nextPage: (totalChanged && wasComplete) ? 2 : nil,
                    total: totalChanged ? pageInfo.count : nil,
                    in: context
                )
            }

            VideoCache.shared.setVideos(videos, for: creator.uid)
            await postNewVideoNotificationsIfNeeded(creator: creator, videos: videos, newlyAdded: newlyAdded, totalNotified: &totalNotified, context: context)
            markInitialSyncIfNeeded(creator: creator, context: context)
            return true
        } catch APIError.rateLimited {
            AppLogger.error("VideoSyncService: B 站限流，停止：\(creator.nickname)")
            return false
        } catch APIError.antiCrawler {
            AppLogger.error("VideoSyncService: B 站风控，停止：\(creator.nickname)")
            return false
        } catch {
            AppLogger.error("VideoSyncService: B 站增量刷新失败 \(creator.nickname): \(error.localizedDescription)")
            return false
        }
    }

    /// 抖音增量刷新单个 creator
    private static func refreshOneDouyin(creator: FollowedCreator, in context: ModelContext, totalNotified: inout Int) async -> Bool {
        let api = DouyinAPIService.shared
        do {
            // 1) 直播状态 — 两条路:
            //    a) fetchUserInfo 返回的 live_room 字段(部分场景下未登录可能缺失)
            //    b) fetchUserLiveStatus 独立端点(覆盖更多场景)
            var liveRoom: LiveRoom? = nil
            if let info = try? await api.fetchUserInfo(secUid: creator.uid), let live = info.liveRoomInfo, !(live.roomId ?? "").isEmpty {
                liveRoom = LiveRoom(
                    id: live.roomId ?? "",
                    roomID: live.roomId ?? "",
                    title: live.title ?? "",
                    coverURL: ensureHTTPS(live.coverURL ?? ""),
                    streamURL: live.streamURL ?? "",
                    viewerCount: live.viewerCount ?? 0,
                    authorUID: creator.uid,
                    authorName: creator.nickname ?? creator.uid,
                    authorAvatar: ensureHTTPS(creator.avatarURL),
                    platform: "douyin",
                    isLive: live.isLiving ?? false
                )
            }
            // 兜底: 调 check_user_live_status 独立端点
            if liveRoom == nil {
                if let status = try? await api.fetchUserLiveStatus(secUid: creator.uid) {
                    // 拿到 webcastId,先放进 LiveRoom(完整信息再调 fetchLiveRoom 拿)
                    liveRoom = LiveRoom(
                        id: status.webcastId,
                        roomID: status.roomId,
                        title: "",
                        coverURL: "",
                        streamURL: "",
                        viewerCount: 0,
                        authorUID: creator.uid,
                        authorName: creator.nickname ?? creator.uid,
                        authorAvatar: ensureHTTPS(creator.avatarURL),
                        platform: "douyin",
                        isLive: true
                    )
                }
            }
            if let liveRoom {
                VideoCache.shared.setLiveRoom(liveRoom, for: creator.uid)
            } else {
                // 明确: 这次刷新没拿到直播状态 — 清掉旧的(避免展示过期"直播中")
                VideoCache.shared.setLiveRoom(nil, for: creator.uid)
            }

            // 2) 拉首页（max_cursor=0 首页；后续 bulkFetch 用返回的 max_cursor）
            let resp = try await api.fetchUserVideos(secUid: creator.uid, maxCursor: 0, count: 40)
            let videos = (resp.awemeList ?? []).map { $0.toVideoItem() }
            let maxCursor = resp.maxCursor ?? 0
            let hasMore = resp.hasMore

            // 3) upsert
            let newlyAdded = try await VideoSyncBackground.run { bgContext in
                VideoCatalog.upsert(videos, into: bgContext)
            }

            // 4) 批量拉取状态（抖音用 max_cursor 翻页,无 pageInfo）
            let totalChanged = creator.bulkFetchTotal != videos.count
            let isLastPage = !(hasMore ?? false) || videos.isEmpty
            let wasComplete = creator.bulkFetchCompletedAt != nil
            if totalChanged || isLastPage {
                VideoCatalog.updateBulkFetchState(
                    for: creator,
                    completedAt: isLastPage ? .some(.now) : .some(nil),
                    nextPage: (totalChanged && wasComplete) ? 2 : nil,
                    total: totalChanged ? videos.count : nil,
                    in: context
                )
            }

            VideoCache.shared.setVideos(videos, for: creator.uid)
            await postNewVideoNotificationsIfNeeded(creator: creator, videos: videos, newlyAdded: newlyAdded, totalNotified: &totalNotified, context: context)
            markInitialSyncIfNeeded(creator: creator, context: context)
            // 暂存 max_cursor 供 bulkFetch 使用
            AppLogger.info("VideoSyncService: 抖音增量刷新 \(creator.nickname) 拉到 \(videos.count) 条, hasMore=\(hasMore), maxCursor=\(maxCursor)")
            return true
        } catch DouyinAPIError.rateLimited {
            AppLogger.error("VideoSyncService: 抖音限流，停止：\(creator.nickname)")
            return false
        } catch DouyinAPIError.antiCrawler {
            AppLogger.error("VideoSyncService: 抖音风控，停止：\(creator.nickname)")
            return false
        } catch {
            AppLogger.error("VideoSyncService: 抖音增量刷新失败 \(creator.nickname): \(error.localizedDescription)")
            return false
        }
    }

    /// 把 "新视频" 通知逻辑抽出来（B/D 共用）
    private static func postNewVideoNotificationsIfNeeded(creator: FollowedCreator, videos: [VideoItem], newlyAdded: Set<Int>, totalNotified: inout Int, context: ModelContext) async {
        guard !newlyAdded.isEmpty && creator.hasCompletedInitialSync else { return }
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

    /// 标记首次同步完成（B/D 共用）
    private static func markInitialSyncIfNeeded(creator: FollowedCreator, context: ModelContext) {
        guard !creator.hasCompletedInitialSync else { return }
        creator.lastModifiedAt = .now
        creator.hasCompletedInitialSync = true
        try? context.save()
        SyncCoordinator.shared.kickUpload()
    }

    /// 全量历史拉取 — 单页
    /// - 平台分发:B 站用 page 号翻页，抖音用 max_cursor 翻页
    /// - 写入 VideoRecord
    /// - 更新 cursor / total / completedAt
    /// - 返回是否还有下一页
    @discardableResult
    static func continueBulkFetch(creator: FollowedCreator, in context: ModelContext) async -> Bool {
        let state = VideoCatalog.bulkFetchState(for: creator)
        if state.isCompleted {
            return false
        }
        switch creator.platform {
        case "bilibili":
            return await continueBulkFetchBilibili(creator: creator, state: state, in: context)
        case "douyin":
            return await continueBulkFetchDouyin(creator: creator, state: state, in: context)
        default:
            return false
        }
    }

    /// B 站 bulk fetch — 按 page 号翻页
    private static func continueBulkFetchBilibili(creator: FollowedCreator, state: VideoCatalog.BulkFetchState, in context: ModelContext) async -> Bool {
        let nextPage = state.nextPage
        let api = BilibiliAPIService.shared
        do {
            let result = try await api.fetchUserVideosWithPageInfo(mid: creator.uid, page: nextPage, pageSize: 30)
            let videos = result.videos
            let pageInfo = result.pageInfo

            try await VideoSyncBackground.run { bgContext in
                _ = VideoCatalog.upsert(videos, into: bgContext)
            }
            VideoCache.shared.appendVideos(videos, for: creator.uid)

            let total = pageInfo.count
            let ps = pageInfo.ps
            let pagesFetched = nextPage
            let totalPages = min((total + ps - 1) / ps, bulkFetchMaxPages)
            // isCompleted 条件: 拉完所有页 OR 视频为空 OR 单页不足 OR **cache 视频数已经 == total**
            // 最后一个条件是为了修复 Bug 1:
            // 当 cache 从磁盘加载已经有了完整数据,而 bulk fetch 因为 aid 重复去重不增加,
            // 单纯的 pagesFetched/totalPages 永远满足不了 → 死循环
            let cachedAfterAppend = VideoCache.shared.videos(for: creator.uid)?.count ?? 0
            let dataAlreadyComplete = total > 0 && cachedAfterAppend >= total
            let isCompleted = pagesFetched >= totalPages || videos.isEmpty || videos.count < ps || dataAlreadyComplete

            VideoCatalog.updateBulkFetchState(
                for: creator,
                completedAt: isCompleted ? .some(.now) : .some(nil),
                nextPage: nextPage + 1,
                total: total,
                in: context
            )

            AppLogger.info("VideoSyncService: B 站 bulk fetch \(creator.nickname) page=\(nextPage)/\(totalPages), returned=\(videos.count), completed=\(isCompleted) (dataAlreadyComplete=\(dataAlreadyComplete))")
            // DEBUG: 验证 Bug 1 - 关键检测: cache 里的视频数 == total 但 completedAt 仍为 nil?
            AppLogger.info("DEBUG continueBulkFetchBilibili: uid=\(creator.uid) name=\(creator.nickname) total=\(total) cached=\(cachedAfterAppend) completedAt=\(isCompleted ? "set to .now" : "kept nil") [after: total=\(creator.bulkFetchTotal) completedAt=\(creator.bulkFetchCompletedAt?.description ?? "nil") nextPage=\(creator.bulkFetchNextPage)]")
            return !isCompleted
        } catch APIError.rateLimited {
            AppLogger.error("VideoSyncService: B 站 bulk fetch 限流，暂停 \(creator.nickname)")
            return true
        } catch APIError.antiCrawler {
            AppLogger.error("VideoSyncService: B 站 bulk fetch 风控，暂停 \(creator.nickname)")
            return true
        } catch {
            AppLogger.error("VideoSyncService: B 站 bulk fetch 失败 \(creator.nickname): \(error.localizedDescription)")
            return true
        }
    }

    /// 抖音 bulk fetch — 按 max_cursor 翻页
    /// - nextPage 在这里复用为"下次拉取的 max_cursor"（与 B 站语义不同）
    /// - bulkFetchTotal 存"本次拉到的视频数"（抖音 API 不返回总数）
    private static func continueBulkFetchDouyin(creator: FollowedCreator, state: VideoCatalog.BulkFetchState, in context: ModelContext) async -> Bool {
        let nextMaxCursor = state.nextPage  // 复用 nextPage 字段存 max_cursor
        let api = DouyinAPIService.shared
        do {
            let resp = try await api.fetchUserVideos(secUid: creator.uid, maxCursor: nextMaxCursor, count: 40)
            let videos = (resp.awemeList ?? []).map { $0.toVideoItem() }
            let newMaxCursor = resp.maxCursor ?? nextMaxCursor
            let hasMore = resp.hasMore

            try await VideoSyncBackground.run { bgContext in
                _ = VideoCatalog.upsert(videos, into: bgContext)
            }
            VideoCache.shared.appendVideos(videos, for: creator.uid)

            let isCompleted = !(hasMore ?? false) || videos.isEmpty
            let pagesFetched = state.nextPage
            let totalPages = pagesFetched + 1  // 累计页数（含本轮）

            VideoCatalog.updateBulkFetchState(
                for: creator,
                completedAt: isCompleted ? .some(.now) : .some(nil),
                nextPage: newMaxCursor,
                total: totalPages >= bulkFetchMaxPages || isCompleted ? creator.bulkFetchTotal : creator.bulkFetchTotal + videos.count,
                in: context
            )

            AppLogger.info("VideoSyncService: 抖音 bulk fetch \(creator.nickname) cursor=\(nextMaxCursor) → \(newMaxCursor), returned=\(videos.count), hasMore=\(hasMore), completed=\(isCompleted)")
            return !isCompleted
        } catch DouyinAPIError.rateLimited {
            AppLogger.error("VideoSyncService: 抖音 bulk fetch 限流，暂停 \(creator.nickname)")
            return true
        } catch DouyinAPIError.antiCrawler {
            AppLogger.error("VideoSyncService: 抖音 bulk fetch 风控，暂停 \(creator.nickname)")
            return true
        } catch {
            AppLogger.error("VideoSyncService: 抖音 bulk fetch 失败 \(creator.nickname): \(error.localizedDescription)")
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
        // 平台分发：抖音也参与 bulk fetch（B 站按 page 翻，抖音按 max_cursor 翻）
        let predicate = #Predicate<FollowedCreator> { $0.bulkFetchCompletedAt == nil }
        let pending = (try? context.fetch(FetchDescriptor<FollowedCreator>(predicate: predicate))) ?? []
        // DEBUG: 验证 Bug 2 - opportunisticBulkFetchStep 实际拿的是哪个 creator
        AppLogger.info("DEBUG opportunisticBulkFetchStep: pending.count=\(pending.count), pending.first=\(pending.first.map { "\($0.nickname)(uid=\($0.uid))" } ?? "nil")")
        guard let next = pending.first else { return 0 }
        let hasMore = await continueBulkFetch(creator: next, in: context)
        return hasMore ? pending.count : pending.count - 1
    }

    /// 机会式批量拉取 — 多页循环
    /// - 在 foreground 触发时调用，一次性推进 N 页（约 3.5s/页，所以 10 页 ≈ 35s）
    /// - 命中 -799 限流/风控会 break 本轮（不再 sleep + 重试），等下次 scenePhase active 再继续
    /// - 支持 Task 取消：用户切后台时取消循环，不会在后台瞎跑
    /// - 返回实际推进的页数
    @discardableResult
    static func opportunisticBulkFetchLoop(in context: ModelContext, maxPages: Int = 10) async -> Int {
        AppLogger.info("DEBUG opportunisticBulkFetchLoop: START maxPages=\(maxPages)")
        var processed = 0
        for i in 0..<maxPages {
            if Task.isCancelled { break }
            let remaining = await opportunisticBulkFetchStep(in: context)
            processed += 1
            AppLogger.info("DEBUG opportunisticBulkFetchLoop: iter=\(i)/\(maxPages) remaining=\(remaining)")
            if remaining == 0 { break }  // 所有 UP 主都拉完了
            // 如果这一页被限流/风控(continueBulkFetch 内部返回 true 表示还有下一页),
            // 区分两种"还有下一页": 真正还有 vs 被限流暂停
            // 限流暂停: 下次大概率还是被限流,继续 sleep 只会浪费电,本轮直接 break
            if await isLikelyRateLimitedOrAntiCrawler() {
                AppLogger.warning("VideoSyncService: 限流/风控,本轮 bulk fetch loop 提前 break,等下次 scenePhase active 再继续 (processed=\(processed)/\(maxPages))")
                break
            }
        }
        AppLogger.info("DEBUG opportunisticBulkFetchLoop: END processed=\(processed)/\(maxPages)")
        if processed > 0 {
            AppLogger.info("VideoSyncService: bulk fetch loop 跑了 \(processed) 页")
        }
        return processed
    }

    /// 检查最近一次 API 调用是否被限流/风控（用于 loop 中提前 break）
    /// 通过查询 BilibiliAPIService 内部计数器判断
    private static func isLikelyRateLimitedOrAntiCrawler() async -> Bool {
        await BilibiliAPIService.shared.isLikelyRateLimitedOrAntiCrawler()
    }

    /// 指定 creator 拉取 — 用于详情页「立即补全历史」按钮
    /// - 只针对传入的 creator,不会去拉其他未完成的
    /// - 一直拉到完成 / 限流 / 跑完 maxPages
    /// - 命中限流/风控时本轮直接退出(break),等用户重新点击再继续
    /// - 返回:(处理的页数, 是否完成)
    @discardableResult
    static func bulkFetchForCreator(creator: FollowedCreator, in context: ModelContext, maxPages: Int = 200) async -> (pages: Int, completed: Bool) {
        let creatorID = creator.uid
        let creatorName = creator.nickname
        AppLogger.info("DEBUG bulkFetchForCreator: START creator=\(creatorName) uid=\(creatorID) maxPages=\(maxPages) [before: completedAt=\(creator.bulkFetchCompletedAt?.description ?? "nil") nextPage=\(creator.bulkFetchNextPage) total=\(creator.bulkFetchTotal) cached=\(VideoCache.shared.videos(for: creatorID)?.count ?? 0)]")
        var pages = 0
        var completed = creator.bulkFetchCompletedAt != nil
        for i in 0..<maxPages {
            if Task.isCancelled { break }
            // 每次循环重新拉一次 creator,避免 detached context 里拿旧引用
            let target = fetchCreator(uid: creatorID, in: context)
            guard let target else {
                AppLogger.warning("VideoSyncService: bulkFetchForCreator 找不到 creator uid=\(creatorID), 中断")
                break
            }
            if target.bulkFetchCompletedAt != nil {
                AppLogger.info("VideoSyncService: bulkFetchForCreator \(creatorName) 已完成,提前 break")
                completed = true
                break
            }
            let hasMore = await continueBulkFetch(creator: target, in: context)
            pages += 1
            if !hasMore {
                completed = true
                break
            }
            // 限流/风控: break
            if await isLikelyRateLimitedOrAntiCrawler() {
                AppLogger.warning("VideoSyncService: bulkFetchForCreator \(creatorName) 限流/风控,本轮退出 (pages=\(pages)/\(maxPages))")
                break
            }
            _ = i
        }
        let finalCached = VideoCache.shared.videos(for: creatorID)?.count ?? 0
        AppLogger.info("DEBUG bulkFetchForCreator: END creator=\(creatorName) pages=\(pages) completed=\(completed) finalCached=\(finalCached)")
        return (pages, completed)
    }

    /// 根据 uid 拉取最新 FollowedCreator 引用(detached context 安全)
    private static func fetchCreator(uid: String, in context: ModelContext) -> FollowedCreator? {
        let predicate = #Predicate<FollowedCreator> { $0.uid == uid }
        return (try? context.fetch(FetchDescriptor<FollowedCreator>(predicate: predicate)))?.first
    }

    /// 把所有已 follow 但还没开始 bulk fetch 的 creator 状态初始化
    /// - bulkFetchNextPage = 2（page 1 由 incremental 拿）
    /// - 应用启动时调用一次即可
    static func ensureBulkFetchInitialized(creators: [FollowedCreator], in context: ModelContext) {
        // 平台分发：抖音也参与
        var didChange = false
        for c in creators where c.platform == "bilibili" || c.platform == "douyin" {
            // bulkFetchNextPage 在 B 站是 page 号，在抖音是 max_cursor
            // 两者都默认是 2（首次 init 时的值）
            if c.bulkFetchNextPage < 2 {
                c.bulkFetchNextPage = 2
                didChange = true
            }
        }
        if didChange {
            try? context.save(); SyncCoordinator.shared.kickUpload()
        }
    }
}
