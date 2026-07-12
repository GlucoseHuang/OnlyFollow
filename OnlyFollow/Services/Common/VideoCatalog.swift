import Foundation
import SwiftData

/// 视频目录服务（SwiftData-backed）
/// 职责：
/// 1. 把 VideoItem upsert 到 VideoRecord 表（首次写入计算 searchTokens；后续更新只刷新动态字段）
/// 2. 提供跨博主的全量搜索
/// 3. 提供 aid 集合查询（增量刷新时判断哪些是"新视频"）
/// 4. 提供批量拉取状态读写
///
/// 线程模型：
/// - 故意不在 @MainActor。upsert 写 30 条记录很快,但和 SwiftData save 一起放在主线程上会卡住 UI
/// - 调用方用 Task.detached + 后台 ModelContext 触发;后台 save 完后 SwiftData 自动 propagate 到主 context
enum VideoCatalog {
    // MARK: - 写入

    /// 把一组 VideoItem 写入（已存在则更新）
    /// - 返回：这次写入中真正新增的 aid（首次入库）
    /// - 性能：先查已有 aid，再决定 insert / update；批量 30 条以内 O(n)
    @discardableResult
    static func upsert(
        _ videos: [VideoItem],
        into context: ModelContext
    ) -> Set<Int> {
        guard !videos.isEmpty else { return [] }

        let aids = videos.map(\.aid)
        // 一次性拉取已存在的 aid
        let existing = fetchRecords(aids: aids, in: context)
        var existingByAid: [Int: VideoRecord] = [:]
        for r in existing { existingByAid[r.aid] = r }

        var insertedAids: Set<Int> = []
        let now = Date()
        for v in videos {
            if let r = existingByAid[v.aid] {
                // 更新：保留 firstSeenAt，刷新其他字段 + titleTokens/authorTokens
                r.bvid = v.bvid
                r.title = v.title
                r.coverURL = v.coverURL
                r.webURL = v.webURL
                r.duration = v.duration
                r.publishTime = v.publishTime
                r.viewCount = v.viewCount
                r.danmakuCount = v.danmakuCount
                r.commentCount = v.commentCount
                r.authorUID = v.authorUID
                r.authorName = v.authorName
                r.authorAvatar = v.authorAvatar
                r.lastRefreshedAt = now
                r.lastModifiedAt = now
                r.titleTokens = SearchTokenizer.tokenString(for: v.title)
                r.authorTokens = SearchTokenizer.tokenString(for: v.authorName)
                // 合集 ID: sync 阶段拿不到(fetchVideoDetail 才有), 但播放过的视频会带过来
                // 用 ?? nil 保护 nil 值不被覆盖(已有但新值是 nil 的情况)
                if let sid = v.ugcSeasonID { r.ugcSeasonID = sid }
                if let st = v.ugcSeasonTitle { r.ugcSeasonTitle = st }
            } else {
                let record = VideoRecord(
                    aid: v.aid,
                    platform: v.platform,
                    bvid: v.bvid,
                    title: v.title,
                    coverURL: v.coverURL,
                    webURL: v.webURL,
                    duration: v.duration,
                    publishTime: v.publishTime,
                    viewCount: v.viewCount,
                    danmakuCount: v.danmakuCount,
                    commentCount: v.commentCount,
                    authorUID: v.authorUID,
                    authorName: v.authorName,
                    authorAvatar: v.authorAvatar,
                    firstSeenAt: now,
                    lastRefreshedAt: now,
                    titleTokens: SearchTokenizer.tokenString(for: v.title),
                    authorTokens: SearchTokenizer.tokenString(for: v.authorName),
                    ugcSeasonID: v.ugcSeasonID,
                    ugcSeasonTitle: v.ugcSeasonTitle
                )
                context.insert(record)
                // 先记下来，但只有 save 成功才会真正算作新增
                insertedAids.insert(v.aid)
            }
        }

        // 严格化：只有 save 成功，insertedAids 才算真正入库
        // 失败时全部不算新增，避免发"假通知"（用户看到通知但库里没数据）
        do {
            try context.save()
        } catch {
            AppLogger.error("VideoCatalog.upsert save failed: \(error.localizedDescription) — \(insertedAids.count) inserts aborted")
            return []
        }
        return insertedAids
    }

    // MARK: - 查询

    private static func fetchRecords(aids: [Int], in context: ModelContext) -> [VideoRecord] {
        // 用 #Predicate 直接按 aid IN 查询
        let predicate = #Predicate<VideoRecord> { aids.contains($0.aid) }
        var fd = FetchDescriptor<VideoRecord>(predicate: predicate)
        fd.fetchLimit = aids.count + 10
        return (try? context.fetch(fd)) ?? []
    }

    /// 全部视频（按发布时间倒序）
    static func allRecords(in context: ModelContext, limit: Int? = nil) -> [VideoRecord] {
        var fd = FetchDescriptor<VideoRecord>(
            sortBy: [SortDescriptor(\.publishTime, order: .reverse)]
        )
        if let limit { fd.fetchLimit = limit }
        return (try? context.fetch(fd)) ?? []
    }

    /// 某个 UP 主的所有视频（用于"补全历史"时的进度展示）
    static func records(forCreatorUID uid: String, in context: ModelContext) -> [VideoRecord] {
        let predicate = #Predicate<VideoRecord> { $0.authorUID == uid }
        return (try? context.fetch(FetchDescriptor<VideoRecord>(predicate: predicate))) ?? []
    }

    // MARK: - 搜索

    struct SearchResult: Identifiable, Hashable {
        let record: VideoRecord
        let score: Int

        var id: Int { record.aid }
        var video: VideoItem { record.toVideoItem() }
    }

    /// 在全表做相关度搜索
    /// - 仅按 token 交集打分；title 命中 > author 命中 > 多字 query 加权
    /// - tiebreak：score desc → viewCount desc → publishTime desc
    static func search(query: String, in context: ModelContext, limit: Int = 200) -> [SearchResult] {
        let qTokens = SearchTokenizer.queryTokens(for: query)
        guard !qTokens.isEmpty else { return [] }

        let records = allRecords(in: context, limit: nil)
        if records.isEmpty { return [] }

        var scored: [SearchResult] = []
        scored.reserveCapacity(records.count / 4)
        for r in records {
            // 优先使用预存的 tokens；旧数据（迁移前写入）字段为空时按需重新计算
            let titleSet = tokensSet(r.titleTokens, fallback: r.title)
            let authorSet = tokensSet(r.authorTokens, fallback: r.authorName)
            let score = SearchTokenizer.score(query: qTokens, titleTokens: titleSet, authorTokens: authorSet)
            if score > 0 {
                scored.append(SearchResult(record: r, score: score))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.record.viewCount != rhs.record.viewCount { return lhs.record.viewCount > rhs.record.viewCount }
            return lhs.record.publishTime > rhs.record.publishTime
        }
        if scored.count > limit {
            scored = Array(scored.prefix(limit))
        }
        return scored
    }

    /// 把空格分隔的 token 字符串切成 Set
    /// 空字符串走 fallback（旧数据迁移用）
    private static func tokensSet(_ stored: String, fallback: String) -> Set<String> {
        if !stored.isEmpty {
            return Set(stored.split(separator: " ").map(String.init))
        }
        return Set(SearchTokenizer.tokens(for: fallback))
    }

    // MARK: - 批量拉取状态

    /// 读取某个 UP 主的批量拉取进度
    static func bulkFetchState(for creator: FollowedCreator) -> BulkFetchState {
        BulkFetchState(
            completedAt: creator.bulkFetchCompletedAt,
            nextPage: creator.bulkFetchNextPage,
            total: creator.bulkFetchTotal
        )
    }

    /// 写入批量拉取进度（page=2 时其实 page 1 已经入库，所以不用重复传视频）
    static func updateBulkFetchState(
        for creator: FollowedCreator,
        completedAt: Date??,
        nextPage: Int?,
        total: Int?,
        in context: ModelContext
    ) {
        // DEBUG: 验证状态机 - 每次写入都打出来
        let completedAtDesc: String
        if completedAt == nil { completedAtDesc = "nil(=不修改)" }
        else if completedAt == .some(nil) { completedAtDesc = ".some(nil)(=不修改,被 if let 跳过)" }
        else if completedAt == .some(.now) { completedAtDesc = ".some(.now)" }
        else { completedAtDesc = ".\(String(describing: completedAt))" }
        AppLogger.info("DEBUG updateBulkFetchState: uid=\(creator.uid) name=\(creator.nickname) completedAt=\(completedAtDesc) nextPage=\(nextPage.map(String.init) ?? "nil") total=\(total.map(String.init) ?? "nil") [before: completedAt=\(creator.bulkFetchCompletedAt?.description ?? "nil") nextPage=\(creator.bulkFetchNextPage) total=\(creator.bulkFetchTotal)]")
        if let completedAt {
            creator.bulkFetchCompletedAt = completedAt
        }
        if let nextPage {
            creator.bulkFetchNextPage = nextPage
        }
        if let total {
            creator.bulkFetchTotal = total
        }
        // 多设备同步：批量拉取进度也是"修改"，刷新 lastModifiedAt
        creator.lastModifiedAt = .now
        try? context.save()
        // kickUpload 是 @MainActor,从 nonisolated 的 updateBulkFetchState 调要异步 dispatch
        Task { @MainActor in
            SyncCoordinator.shared.kickUpload()
        }
    }

    struct BulkFetchState {
        let completedAt: Date?
        let nextPage: Int
        let total: Int
        var isCompleted: Bool { completedAt != nil }
    }
}
