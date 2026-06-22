import Foundation
import SwiftData
import SwiftUI

/// 「合集补全」状态(全局单例, 给 SettingsView 展示进度用)
@MainActor
final class SeasonBackfillState: ObservableObject {
    static let shared = SeasonBackfillState()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var processed: Int = 0
    @Published private(set) var total: Int = 0
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastMatchedCount: Int = 0
    @Published private(set) var lastError: String?
    /// 本地已识别到的合集数(去重: (mid, seasonID))
    @Published private(set) var knownSeasonCount: Int = 0

    private init() {}

    /// 由 SeasonListSheet 的「补全本合集所有视频」按钮调用
    func startBackfillOne(mid: String, seasonID: Int, context: ModelContext) {
        guard !isRunning else {
            AppLogger.info("SeasonBackfillState: 已有任务在跑, 忽略 manual")
            return
        }
        isRunning = true
        processed = 0
        total = 1
        lastError = nil
        AppLogger.info("SeasonBackfillState: 手动补全开始 seasonID=\(seasonID)")
        Task { [weak self] in
            // bypassDebounce: true — 手动按钮用户主动点的, 不受 60s 限制
            let n = await SeasonBackfillService.backfillOne(
                mid: mid, seasonID: seasonID, in: context, fetchAll: true, bypassDebounce: true
            )
            await MainActor.run {
                self?.isRunning = false
                self?.lastRunAt = Date()
                self?.lastMatchedCount = n
                AppLogger.info("SeasonBackfillState: 单合集补全完成, 匹配 \\(n) 个")
                self?.refreshKnownCount(context: context)
            }
        }
    }

    /// 由 Settings 的「补全所有已知合集」按钮调用
    func startBackfillAll(context: ModelContext) {
        guard !isRunning else {
            AppLogger.info("SeasonBackfillState: 已有任务在跑, 忽略")
            return
        }
        isRunning = true
        processed = 0
        total = 0
        lastError = nil
        Task { [weak self] in
            await SeasonBackfillService.backfillAll(in: context) { p, t in
                Task { @MainActor in
                    self?.processed = p
                    self?.total = t
                }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.lastRunAt = Date()
                AppLogger.info("SeasonBackfillState: 全量补全完成")
                self?.refreshKnownCount(context: context)
            }
        }
    }

    /// 重新计算已知合集数(给 SettingsView 显示"已发现 N 个合集")
    func refreshKnownCount(context: ModelContext) {
        let allRecords = (try? context.fetch(FetchDescriptor<VideoRecord>())) ?? []
        var groups: Set<String> = []
        for r in allRecords {
            if let sid = r.ugcSeasonID {
                groups.insert("\\(r.authorUID)|\\(sid)")
            }
        }
        knownSeasonCount = groups.count
    }
}
