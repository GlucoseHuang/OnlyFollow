import Foundation
import SwiftData
import SwiftUI

/// 多设备同步的协调器
///
/// 职责：
/// 1. 监听 SwiftData 变化（通过调用方调 `kickUpload()`），debounce 5 秒后推送到云端
/// 2. 启动 / 回前台 / "立即同步" 按钮触发拉取
/// 3. App 退后台时强制 flush 一次（避免丢最后一波改动）
/// 4. 对外暴露 status 供 UI 显示
///
/// 调用入口：
/// - `kickUpload()` — 任何 SwiftData 保存后调用
/// - `pullNow()` — 立即从云端拉一次（手动同步按钮 / 回前台）
/// - `flushPending()` — App 退后台时调用
///
/// 调用方负责的事情：
/// - 把 modelContext 注入（`.attachModelContext(_:)`）
/// - 把 modelContext 上的改动通过 `kickUpload()` 通知过来
@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()

    // MARK: - 配置

    /// 上传 debounce。5 秒吸收 burst，详见 plan
    private let uploadDebounceSeconds: TimeInterval = 5

    // MARK: - 状态

    enum Status: Equatable {
        /// 刚启动 / 还没决定要不要同步
        case idle
        /// 云同步不可用（未登录 / 容器拿不到）
        case unavailable(reason: String)
        /// 正在从本地读 + 编码
        case exporting
        /// 正在上传到云端
        case uploading
        /// 正在从云端下载 + 解析
        case downloading
        /// 正在合并到本地 SwiftData
        case merging
        /// 出错了，等下次触发
        case error(String)
        /// 同步成功（最后一次成功的时间）
        case success(lastSyncedAt: Date)

        var isWorking: Bool {
            switch self {
            case .exporting, .uploading, .downloading, .merging: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle

    /// 给 UI 用的最后同步时间
    @Published private(set) var lastSyncedAt: Date?

    // MARK: - 内部状态

    private var modelContext: ModelContext?
    private var debounceTask: Task<Void, Never>?
    private var isUploading = false
    private var isPulling = false

    // MARK: - 生命周期

    private init() {}

    /// 启动（OnlyFollowApp.init 调用）
    /// - 启动 SyncStorage（NSMetadataQuery 监听）
    /// - 注册 UI 通知
    func start() {
        SyncStorage.shared.start()
        // 监听云端文件变化 → 触发拉取
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoteChange),
            name: SyncStorage.remoteChangeNotification,
            object: nil
        )
        // 监听云同步状态变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStorageStateChange),
            name: SyncStorage.stateChangeNotification,
            object: nil
        )
    }

    /// 注入 modelContext（app 启动时由 root view 调用一次）
    func attachModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - 上传

    /// 通知 coordinator "本地有变化"；debounce 5 秒后上传
    /// - 多次调用会重置计时器
    func kickUpload() {
        guard SyncStorage.shared.availability == .available else {
            AppLogger.info("SyncCoordinator: kickUpload ignored, 云同步不可用")
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.uploadDebounceSeconds ?? 5) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.performUpload()
        }
    }

    /// 强制 flush（App 退后台时调用；不等待 debounce）
    func flushPending() {
        debounceTask?.cancel()
        debounceTask = nil
        Task { [weak self] in
            await self?.performUpload()
        }
    }

    private func performUpload() async {
        guard !isUploading else {
            AppLogger.info("SyncCoordinator: upload already in progress, skipping")
            return
        }
        guard let context = modelContext else { return }
        guard SyncStorage.shared.availability == .available else {
            status = .unavailable(reason: SyncStorage.unavailableReason)
            return
        }

        guard SyncStorage.shared.hasCompletedInitialPull else {
            AppLogger.info("SyncCoordinator: upload skipped, waiting for first pull to complete (prevents empty snapshot overwriting remote)")
            return
        }

        isUploading = true
        defer { isUploading = false }

        status = .exporting
        let snapshot: SyncSnapshot
        do {
            // 后台线程导出 + 编码（CPU bound）
            snapshot = try await Task.detached(priority: .utility) {
                let snap = await SyncExporter.exportAll(from: context)
                _ = try SyncCodec.encode(snap) // 预热一下，顺便让编码失败在这里抛
                return snap
            }.value
        } catch {
            AppLogger.error("SyncCoordinator: export/encode failed: \(error.localizedDescription)")
            status = .error("导出失败: \(error.localizedDescription)")
            return
        }

        status = .uploading
        do {
            try await SyncStorage.shared.writeSnapshot(snapshot)
            let now = Date()
            lastSyncedAt = now
            status = .success(lastSyncedAt: now)
            AppLogger.info("SyncCoordinator: upload ok (\(snapshot.creators.count) creators, \(snapshot.videos.count) videos)")
        } catch {
            AppLogger.error("SyncCoordinator: upload failed: \(error.localizedDescription)")
            status = .error("上传失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 拉取

    /// 立即从云端拉一次并 merge
    /// - 启动 / 回前台 / 手动同步按钮 → 调用
    func pullNow() async {
        guard !isPulling else {
            AppLogger.info("SyncCoordinator: pull already in progress, skipping")
            return
        }
        guard SyncStorage.shared.availability == .available else {
            status = .unavailable(reason: SyncStorage.unavailableReason)
            return
        }
        guard let context = modelContext else { return }

        isPulling = true
        defer { isPulling = false }

        status = .downloading
        let snapshot: SyncSnapshot?
        do {
            snapshot = try await SyncStorage.shared.readSnapshot()
        } catch {
            AppLogger.error("SyncCoordinator: readSnapshot failed: \(error.localizedDescription)")
            status = .error("下载失败: \(error.localizedDescription)")
            return
        }

        guard let snap = snapshot else {
            // 云端没文件；如果是首次安装,这很正常
            // 但这次 pull 仍然算"已确认过状态":远端为空,我们可以放心上传本地数据
            AppLogger.info("SyncCoordinator: no remote snapshot, marking initial pull complete")
            SyncStorage.shared.markInitialPullCompleted()
            status = lastSyncedAt.map { .success(lastSyncedAt: $0) } ?? .idle
            // 顺手把本地数据推上去(如果有),让远端不再为空
            flushPending()
            return
        }

        // 如果是本设备自己刚写的快照,跳过 merge(自己跟自己合并没意义)
        // 但也算"已确认过状态":远端就是我们刚写的
        if snap.deviceID == SyncStorage.shared.deviceID {
            AppLogger.info("SyncCoordinator: remote snapshot is from this device, marking initial pull complete")
            SyncStorage.shared.markInitialPullCompleted()
            status = .success(lastSyncedAt: lastSyncedAt ?? Date())
            return
        }

        status = .merging
        do {
            // 2200+ 条记录的 merge + 单次 save 已知在 iOS 17/18 SwiftData 上会阻塞主线程数秒
            // (Apple 自家论坛都建议把 SwiftData save 挪到 detached Task 上)
            // 用后台 ModelContext 跑 merge,save 完后 SwiftData 自动 propagate 到主 context
            let stats = try await Self.runMergeOnBackground(snap: snap)
            // 合并成功 = 已经知道远端状态,可以放行后续上传
            SyncStorage.shared.markInitialPullCompleted()
            // pull 后立刻用快照里的视频填 VideoCache,首页 / 详情页不用再手动刷新
            populateVideoCache(from: snap)
            let now = Date()
            lastSyncedAt = now
            status = .success(lastSyncedAt: now)
            AppLogger.info("SyncCoordinator: pull+merge ok — \(stats.summary)")
            // merge 后立刻把合并结果推回去,作为一次幂等确认;后续的 kickUpload 仍走 5s debounce
            flushPending()
        } catch {
            AppLogger.error("SyncCoordinator: merge failed: \(error.localizedDescription)")
            status = .error("合并失败: \(error.localizedDescription)")
        }
    }

    /// 在后台线程 + 后台 ModelContext 上跑 SyncMerger.merge。
    /// SwiftData 的 background context save 完后会自动 propagate 到主 context,
    /// 任何订阅了 @Query 的 view 都会自动刷新。
    /// - 关键:SyncMerger 是 nonisolated 的(我刚去掉了 @MainActor),才能从 detached task 调
    private static func runMergeOnBackground(snap: SyncSnapshot) async throws -> MergeStats {
        let container = OnlyFollowApp.sharedContainer
        return try await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            return try SyncMerger.merge(snap, into: bgContext)
        }.value
    }


    // MARK: - 缓存填充

    /// 把快照里的视频按 authorUID 分组,填进 VideoCache,首页 / 详情页立刻就有内容看
    /// - 触发时机:远端 snapshot merge 到 SwiftData 之后
    /// - 不依赖 SwiftData 主 context(直接用 DTO 构造 VideoItem),所以在 background merge 刚结束时立刻调没问题
    /// - 空 cache 用 setVideos 全量覆盖;非空 cache 用 appendVideos 只补新 aid,避免覆盖本地更"新"的 viewCount
    private func populateVideoCache(from snap: SyncSnapshot) {
        guard !snap.videos.isEmpty else {
            AppLogger.info("SyncCoordinator: populateVideoCache skipped, snapshot has no videos")
            return
        }
        var byCreator: [String: [VideoItem]] = [:]
        for v in snap.videos {
            byCreator[v.authorUID, default: []].append(v.toVideoItem())
        }
        var populated = 0
        var appended = 0
        for (uid, videos) in byCreator {
            let existing = VideoCache.shared.videos(for: uid) ?? []
            if existing.isEmpty {
                VideoCache.shared.setVideos(videos, for: uid)
                populated += 1
            } else {
                VideoCache.shared.appendVideos(videos, for: uid)
                appended += 1
            }
        }
        AppLogger.info("SyncCoordinator: populateVideoCache done - set=\\(populated), append=\\(appended), videos=\\(snap.videos.count)")
    }

    // MARK: - 通知回调

    @objc private func handleRemoteChange() {
        // 云端文件变化 → 拉一次
        // 写后回调也会触发这里（因为我们后端写完上传后会通知 listener(预留接口)）
        // 但 performUpload 里已经过滤了"自己写的"，所以这里直接 pull
        Task { [weak self] in
            await self?.pullNow()
        }
    }

    @objc private func handleStorageStateChange() {
        // 云同步状态变化 → 刷新 status
        switch SyncStorage.shared.availability {
        case .available:
            // 状态恢复到 .success（如果有 lastSyncedAt）或者 .idle
            status = lastSyncedAt.map { .success(lastSyncedAt: $0) } ?? .idle
        case .unavailable(let reason):
            status = .unavailable(reason: reason)
        case .unknown:
            status = .idle
        }
    }
}

// MARK: - 便利扩展

extension SyncStorage {
    /// UI 用的"为什么不可用"字符串
    static var unavailableReason: String {
        switch shared.availability {
        case .unavailable(let reason): return reason
        case .available: return ""
        case .unknown: return "正在检查云同步状态…"
        }
    }
}

extension ModelContext {
    /// SwiftData 保存后立即触发同步上传
    /// - 调用方在所有改动完后调一次
    /// - 失败不抛出（与现有 try? context.save() 行为一致）
    @discardableResult
    @MainActor
    func saveAndKickSync() -> Bool {
        do {
            try save()
            SyncCoordinator.shared.kickUpload()
            return true
        } catch {
            AppLogger.error("saveAndKickSync failed: \(error.localizedDescription)")
            return false
        }
    }
}
