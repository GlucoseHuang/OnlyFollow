import Foundation
import SwiftUI

/// 跨页面共享的 UP 主视频缓存
/// - 内存：所有观察者共享同一份数据，进入详情页不需要重新拉取
/// - 磁盘：JSON 持久化，重启 App 仍有上次内容（7 天内视为有效）
/// - 拉取策略：app 启动时不自动拉（除非 cache 为空）；只有用户主动下拉刷新或「加载更多」才请求
@MainActor
final class VideoCache: ObservableObject {
    static let shared = VideoCache()

    @Published private(set) var videosByCreator: [String: [VideoItem]] = [:]
    @Published private(set) var liveRoomByCreator: [String: LiveRoom] = [:]
    /// 每个 UP 主最近一次成功拉取的时间（用于 UI 显示"最后更新于 X"）
    @Published private(set) var lastRefreshedAt: [String: Date] = [:]

    private let cacheFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("video_cache.json")
    }()

    /// 串行后台队列：JSON 编码 + 原子写磁盘
    /// - 串行避免并发写同一个文件
    /// - utility QoS 不抢占主线程 CPU
    private let persistQueue = DispatchQueue(label: "com.onlyfollow.VideoCache.persist", qos: .utility)

    private init() {
        // 启动慢修复: 之前在 init 同步 loadFromDisk, 11MB JSON 解码阻塞主线程 100-500ms
        //   App 启动时 VideoCache.shared = VideoCache() 是第一次访问, 直接卡白屏
        // 修法: init 立刻返回, load 在后台 Task 里跑, 完成后跳回主线程更新 @Published
        //   期间 videosByCreator 为空, 视图显示「暂无数据」, 不影响首屏其他 UI
        loadFromDiskAsync()
    }

    private func loadFromDiskAsync() {
        let url = cacheFileURL
        Task.detached(priority: .userInitiated) {
            // 后台线程: 读文件 + JSON 解码 (CPU/IO bound, 不在主线程跑)
            guard let data = try? Data(contentsOf: url) else { return }
            guard let shape = try? JSONDecoder().decode(PersistShape.self, from: data) else { return }

            // 跳回主线程: 写 @Published (必须在 MainActor)
            await MainActor.run {
                self.videosByCreator = shape.videos
                self.liveRoomByCreator = shape.liveRooms
                let defaultDate = Date().addingTimeInterval(-3600)
                for key in shape.videos.keys {
                    self.lastRefreshedAt[key] = defaultDate
                }
                AppLogger.info("VideoCache: loaded \(shape.videos.count) creators from disk")
            }
        }
    }

    // MARK: - 读取

    /// 读取 UP 主视频（内存命中即返回；磁盘已在 init 时全部加载进内存）
    func videos(for uid: String) -> [VideoItem]? {
        videosByCreator[uid]
    }

    func liveRoom(for uid: String) -> LiveRoom? {
        liveRoomByCreator[uid]
    }

    /// 格式化"最后更新于 X"文案
    func lastRefreshedString(for uid: String) -> String {
        guard let date = lastRefreshedAt[uid] else { return "尚未更新" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚更新" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前更新" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前更新" }
        return "\(Int(interval / 86400)) 天前更新"
    }

    // MARK: - 写入

    /// 写入 UP 主视频（同时更新内存与磁盘；与现有数据合并，新数据胜出）
    /// - 用于 incremental refresh：传入 page 1（30 条），与缓存里已有的 bulk fetch / load more 视频合并
    /// - 不能直接替换，否则下一次 incremental refresh 会把 bulk fetch 加进去的视频清掉
    func setVideos(_ videos: [VideoItem], for uid: String) {
        let existing = videosByCreator[uid] ?? []
        var byAid: [String: VideoItem] = [:]
        for v in existing { byAid[v.id] = v }
        for v in videos { byAid[v.id] = v }  // 新的覆盖旧的（viewCount 等字段刷新）
        videosByCreator[uid] = Array(byAid.values).sorted { $0.publishTime > $1.publishTime }
        lastRefreshedAt[uid] = Date()
        persistToDisk()
    }

    /// 追加分页（用于「加载更多」和 bulk fetch），保持已有顺序去重
    func appendVideos(_ more: [VideoItem], for uid: String) {
        let existing = videosByCreator[uid] ?? []
        var seen = Set(existing.map(\.id))
        var merged = existing
        for v in more where !seen.contains(v.id) {
            merged.append(v)
            seen.insert(v.id)
        }
        videosByCreator[uid] = merged
        lastRefreshedAt[uid] = Date()
        persistToDisk()
    }

    func setLiveRoom(_ room: LiveRoom?, for uid: String) {
        liveRoomByCreator[uid] = room
        persistToDisk()
    }

    func invalidate(uid: String) {
        videosByCreator.removeValue(forKey: uid)
        liveRoomByCreator.removeValue(forKey: uid)
        lastRefreshedAt.removeValue(forKey: uid)
        persistToDisk()
    }

    // MARK: - 持久化

    private struct PersistShape: Codable {
        var videos: [String: [VideoItem]]
        var liveRooms: [String: LiveRoom]
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return }
        guard let shape = try? JSONDecoder().decode(PersistShape.self, from: data) else { return }
        videosByCreator = shape.videos
        liveRoomByCreator = shape.liveRooms
        // 从磁盘恢复时，把 lastRefreshedAt 设为 1 小时前，UI 会提示"X 小时前更新"
        // 避免误导用户以为数据是最新的
        let defaultDate = Date().addingTimeInterval(-3600)
        for key in videosByCreator.keys {
            lastRefreshedAt[key] = defaultDate
        }
        AppLogger.info("VideoCache: loaded \(shape.videos.count) creators from disk")
    }

    private func persistToDisk() {
        // 设计问题修复：之前 persistToDisk 在 @MainActor 上同步做
        //   JSONEncoder().encode(11MB) + atomic write, 单次 100-500ms
        //   bulk fetch 11 个 UP 主触发 11 次 → 主线程累计被卡 1-5 秒
        //   表现为「过几秒卡一下」+ 按钮无响应 + 弹幕冻结
        //
        // 修法: 值类型快照在主线程做（COW 引用赋值 O(1), 跟原来一样快),
        //       JSON 编码 + atomic write 丢到后台串行队列,
        //       主线程立刻返回, 不再被磁盘 I/O 阻塞。
        //
        // 线程安全: PersistShape 是值类型, 字典的 COW 语义保证
        //   `videosByCreator` 引用赋值是原子操作, 后台拿到独立副本。
        //   后续若主线程修改 videosByCreator (新引用), 后台继续用它自己的快照, 不冲突。
        let shape = PersistShape(videos: videosByCreator, liveRooms: liveRoomByCreator)
        persistQueue.async { [cacheFileURL] in
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }
}
