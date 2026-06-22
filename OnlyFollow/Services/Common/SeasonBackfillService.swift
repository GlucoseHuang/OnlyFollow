import Foundation
import SwiftData

/// 合集本地补全服务
/// - 触发 1（自动）：用户播放某个合集视频时, loadCollectionFromLocal 完成后异步触发
///   backfillOne(fetchAll: false), 拉该合集第一页 30 个, 跟本地匹配写回 ugcSeasonID
/// - 触发 2（手动-单合集）：SeasonListSheet 顶部的「补全本合集所有视频」按钮,
///   backfillOne(fetchAll: true), 分页拉完整个合集(每页 30, 限流 1.5s)
/// - 触发 3（手动-所有合集）：Settings 的「补全所有已知合集」按钮,
///   对所有 (mid, seasonID) 组合各跑一次 backfillOne(fetchAll: false)
///
/// - API 限流：每次请求 sleep 1.5s
/// - inFlight 去重：避免同一合集被并发触发
/// - 限速上限：单合集 fetchAll=true 时最多 50 页(1500 个视频), 防止超长合集超时
@MainActor
enum SeasonBackfillService {
    /// 合集 API 限流间隔(秒)
    private static let requestInterval: TimeInterval = 1.5
    /// 单合集 fetchAll=true 时最多拉的页数(1500 视频)
    private static let maxPagesPerSeason: Int = 50

    /// 正在 backfill 的合集 seasonID(防止并发)
    private static var inFlight: Set<Int> = []
    /// 每个合集上次 backfill 的时间戳(静态, 跨 VM 共享)
    /// - 防止切歌/切合集时反复拉同一合集
    /// - 手动 fetchAll=true 会绕过这个 debounce
    private static var lastBackfillTime: [Int: Date] = [:]
    /// 自动 backfill 的最小间隔(秒) — 同一合集在这个间隔内不会重复拉
    private static let autoDebounceInterval: TimeInterval = 60

    /// 补全单个合集(mid + seasonID)
    /// - fetchAll=false: 1 页 (30 个, 用于自动触发和"补全所有已知合集")
    /// - fetchAll=true:  所有页(用于"补全本合集所有视频")
    /// - 返回: 这次匹配上的本地视频数
    @discardableResult
    static func backfillOne(
        mid: String,
        seasonID: Int,
        in context: ModelContext,
        fetchAll: Bool = false,
        bypassDebounce: Bool = false
    ) async -> Int {
        // 去重(防止同一合集被并发触发, 比如同时点了 sheet 按钮 + 设置按钮)
        if inFlight.contains(seasonID) {
            AppLogger.info("SeasonBackfill: season_id=\(seasonID) 已在补全中, 跳过")
            return 0
        }
        // 时间 debounce(仅自动模式) — 静态, 跨 VM 共享, 防止切歌时反复拉
        if !bypassDebounce {
            if let last = lastBackfillTime[seasonID],
               Date().timeIntervalSince(last) < autoDebounceInterval {
                AppLogger.info("SeasonBackfill: season_id=\(seasonID) \(Int(autoDebounceInterval))s 内已自动补全过, 跳过")
                return 0
            }
        }
        inFlight.insert(seasonID)
        lastBackfillTime[seasonID] = Date()
        defer { inFlight.remove(seasonID) }

        AppLogger.info("SeasonBackfill: 开始 season_id=\(seasonID) fetchAll=\(fetchAll) bypassDebounce=\(bypassDebounce)")

        // 分页拉
        var pageNum = 1
        var totalMatched = 0
        let pageSize = 30
        let maxPages = fetchAll ? maxPagesPerSeason : 1
        var seasonTitle: String?

        for _ in 0..<maxPages {
            let resp: BilibiliSeasonArchivesResponse
            do {
                resp = try await BilibiliAPIService.shared.fetchSeasonArchives(
                    mid: mid, seasonID: seasonID, pageNum: pageNum, pageSize: pageSize
                )
            } catch {
                AppLogger.error("SeasonBackfill: 拉 season_id=\(seasonID) page=\(pageNum) 失败: \(error.localizedDescription)")
                return totalMatched
            }

            // 第一次拉取时记录合集标题
            if pageNum == 1, let name = resp.meta?.name {
                seasonTitle = name
            }

            // 跟本地 VideoRecord 匹配
            // 关键: 之前用 #Predicate { video in aids.contains(video.aid) } 静默返回 0 行
            // (跟 #Predicate { $0.aid == aid } 一样, SwiftData macro 有静默失败问题)
            // 直接用 fetch all + in-memory filter: 6256 条遍历, 30 个 aid 的 set 包含查询, 速度完全 OK
            let aids = resp.archives.map(\.aid)
            let allRecords = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
            let aidSet = Set(aids.map { Int64($0) })  // Int64 兼容 SwiftData 内部类型
            let existingRecords = allRecords.filter { aidSet.contains(Int64($0.aid)) }
            AppLogger.info("SeasonBackfill: page=\(pageNum) fetch-all 命中 \(existingRecords.count)/\(aids.count) 个(本地 \(allRecords.count) 条)")

            // 更新(只填没填过的, 避免覆盖)
            // 关键: 用 Int64 做 key, 跟 SwiftData 内部 SQLite INTEGER 保持类型一致
            //   之前用 Int 当 key 时, byAid[archive.aid] 总是 nil, 所以匹配永远是 0
            var byAid: [Int64: VideoRecord] = [:]
            for r in existingRecords { byAid[Int64(r.aid)] = r }
            var pageUpdated = 0
            let now = Date()
            for archive in resp.archives {
                guard let r = byAid[Int64(archive.aid)] else { continue }
                if r.ugcSeasonID == nil {
                    r.ugcSeasonID = seasonID
                    pageUpdated += 1
                }
                if r.ugcSeasonTitle == nil, let t = seasonTitle {
                    r.ugcSeasonTitle = t
                    pageUpdated += 1
                }
                r.lastRefreshedAt = now
            }
            if pageUpdated > 0 {
                try? context.save()
            }
            // 关键: 累计"实际新匹配"(用于 VM 决定是否刷新 seasonPlaylist)
            //   不要算"已存在的匹配", 否则永远 n>0, 永远 reload
            totalMatched += pageUpdated
            AppLogger.info("SeasonBackfill: season_id=\(seasonID) page=\(pageNum) 新匹配 \(pageUpdated)/\(resp.archives.count) (总累计 \(totalMatched))")

            // 翻页判断: 返回的 page.total <= pageNum * pageSize 就到底了
            if let pageInfo = resp.page {
                if pageInfo.total <= pageNum * pageSize {
                    break
                }
            } else {
                // 没 page 字段兜底: archives 不到 pageSize 也到底
                if resp.archives.count < pageSize {
                    break
                }
            }
            pageNum += 1
            // 限流: 页间 sleep(最后一页不睡)
            try? await Task.sleep(for: .seconds(requestInterval))
        }

        if totalMatched == 0 {
            AppLogger.info("SeasonBackfill: season_id=\(seasonID) 全程没匹配到本地视频(本地还没缓存这些 aid)")
        }
        return totalMatched
    }

    /// 补全所有已知合集(在 main actor 上调用)
    /// - 扫描所有 ugcSeasonID != nil 的本地 VideoRecord
    /// - 按 (mid, seasonID) 分组去重
    /// - 串行 await backfillOne(避免限流)
    /// - onProgress 回调: (已完成数, 总数)
    static func backfillAll(
        in context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async {
        // 找所有有 ugcSeasonID 的本地视频
        let desc = FetchDescriptor<VideoRecord>()
        let allRecords = (try? context.fetch(desc)) ?? []
        // 按 (mid, seasonID) 分组
        var groups: [String: (mid: String, seasonID: Int)] = [:]
        for r in allRecords {
            guard let sid = r.ugcSeasonID, !r.authorUID.isEmpty else { continue }
            let key = "\(r.authorUID)|\(sid)"
            if groups[key] == nil {
                groups[key] = (mid: r.authorUID, seasonID: sid)
            }
        }
        let total = groups.count
        AppLogger.info("SeasonBackfill: 开始全量补全, 共 \(total) 个合集")
        onProgress?(0, total)

        var done = 0
        for (_, g) in groups {
            _ = await backfillOne(mid: g.mid, seasonID: g.seasonID, in: context, fetchAll: false)
            done += 1
            onProgress?(done, total)
            // 限流: 合集间 sleep
            try? await Task.sleep(for: .seconds(requestInterval))
        }
        AppLogger.info("SeasonBackfill: 全量补全完成")
    }
}
