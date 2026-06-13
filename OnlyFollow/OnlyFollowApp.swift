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
        ])
        do {
            let container = try ModelContainer(for: schema)
            AppLogger.info("ModelContainer created. Schema: \(schema.entities.map(\.name))")
            return container
        } catch {
            AppLogger.error("ModelContainer creation failed: \(error.localizedDescription)")
            fatalError("Cannot create ModelContainer: \(error)")
        }
    }()

    init() {
        // BGTask 注册必须在 scene 变 active 之前完成
        BackgroundTaskService.register(modelContainer: Self.sharedContainer)
        BackgroundTaskService.scheduleIncrementalRefresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.sharedContainer)
    }
}
