import SwiftUI
import SwiftData

@main
struct OnlyFollowApp: App {
    /// 共享的 ModelContainer：SwiftUI scene 和后台任务（BGAppRefreshTask）都从这里取
    /// - 必须用 static lazy，让 registerBGTask 能在 init 阶段拿到
    static let sharedContainer: ModelContainer = {
        let schema = Schema([
            FollowedCreator.self,
            FavoriteVideo.self,
            PlaylistItem.self,
            PlaybackHistory.self,
            VideoRecord.self,
            LiveHistory.self,
            VideoEmbedding.self,
        ])
        // 使用固定 URL，方便"schema 变了清空旧库"的处理
        let storeURL = URL.applicationSupportDirectory.appending(path: "OnlyFollow.store")
        // 检查 schema 版本；不匹配则清空旧库
        Self.maybeWipeStoreIfSchemaChanged(at: storeURL)
        let config = ModelConfiguration(url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.info("ModelContainer created. Schema: \(schema.entities.map(\.name)), store: \(storeURL.path)")
            return container
        } catch {
            // 启动时如果还失败，store 可能是上一次异常留下的；再删一次重试
            AppLogger.error("ModelContainer creation failed, retrying with wipe: \(error.localizedDescription)")
            Self.wipeStore(at: storeURL)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                AppLogger.error("ModelContainer creation failed even after wipe: \(error.localizedDescription)")
                fatalError("Cannot create ModelContainer: \(error)")
            }
        }
    }()

    /// 当前的 schema 版本号；改了 @Model 字段就 +1
    /// - 启动时如果 UserDefaults 里的版本号 < 当前值，说明有 schema 变化；清空旧 store
    /// - 不在 UserDefaults 里"第一次跑"时（== 0）也清空，安全起见
    private static let schemaVersionKey = "sync.schemaVersion"
    private static let currentSchemaVersion = 4  // v4: 新增 VideoEmbedding（本地向量缓存,不入同步快照）。
                                                  // PlaybackHistory 新增 partCid/partPage/partTitle 字段,
                                                  // 但 schemaVersion 不 bump,SwiftData 靠默认值自动给老记录填 0/0/"",
                                                  // 这样用户的本地播放历史不会被 wipe 掉。

    /// 检查 schema 版本；如果不匹配，删 store 文件
    private static func maybeWipeStoreIfSchemaChanged(at url: URL) {
        let stored = UserDefaults.standard.integer(forKey: schemaVersionKey)
        if stored >= currentSchemaVersion {
            return  // 已经升级过了
        }
        AppLogger.info("Schema version bump: stored=\(stored), current=\(currentSchemaVersion) — wiping old store")
        wipeStore(at: url)
        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        // SwiftData 被 wipe 后本地是空的;如果此时 sync 已配置过,必须重新 pull 才能再次上传
        // 否则在"merge 完成"之前任何 upload 触发都会把空快照推上去覆盖远端
        UserDefaults.standard.set(false, forKey: "sync.hasCompletedInitialPull")
    }

    /// 删 store 主文件 + WAL + SHM
    private static func wipeStore(at url: URL) {
        let fm = FileManager.default
        let candidates = [
            url,
            url.appendingPathExtension("wal"),
            url.appendingPathExtension("shm")
        ]
        for path in candidates {
            try? fm.removeItem(at: path)
            AppLogger.info("Wiped store file: \(path.lastPathComponent)")
        }
    }

    init() {
        // BGTask 注册必须在 scene 变 active 之前完成
        BackgroundTaskService.register(modelContainer: Self.sharedContainer)
        BackgroundTaskService.scheduleIncrementalRefresh()
        // 启动抖音 Session（后台加载抖音首页 WKWebView以取签名/cookie）
        // - WKWebView 加载约需 3s，趁启动后台跑，不阻塞 UI
        Task { @MainActor in
            DouyinSessionManager.shared.initialize()
        }
        // 启动 iCloud 同步协调器（NSMetadataQuery 等）
        SyncCoordinator.shared.start()
        // 启动一次「本地向量」增量建库(后台跑, 不阻塞启动)
        Task.detached(priority: .background) {
            let context = ModelContext(Self.sharedContainer)
            do {
                let updated = try await VideoEmbedder.runOnce(context: context)
                if updated > 0 {
                    AppLogger.info("OnlyFollowApp: 启动建库更新了 \(updated) 条 embedding")
                }
            } catch {
                AppLogger.error("OnlyFollowApp: 启动建库失败: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.sharedContainer)
    }
}
