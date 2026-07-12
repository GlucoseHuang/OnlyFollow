import Foundation
import Combine

/// 平台无关的直播弹幕服务包装
///
/// 把 BilibiliDanmakuService / DouyinDanmakuService 这两个 ObservableObject
/// 通过 Combine sink 桥接到统一的 @Published messages / isConnected 接口上。
///
/// 动机：
/// - LiveRoomView 不再硬编码具体服务，而是用这个 host
/// - load() 里先调平台特定的"取签名/取 token"接口，然后建具体 service，最后 attach 到 host
/// - view body 只需要观察 host 的属性，不用关心底层是 B 还是 D
///
/// 设计：
/// - 用 Combine sink 桥接（不是 protocol，ObservableObject 不能用 protocol 约束 @Published）
/// - attach 可被多次调用，每次换底层 service 并重建 sink（B 站需要先拿 token 再创建）
@MainActor
final class LiveDanmakuHost: ObservableObject {
    @Published private(set) var messages: [DanmakuMessage] = []
    @Published private(set) var isConnected: Bool = false
    /// 直播间实时人数 (抖音: WebcastRoomStatsMessage 的 displayLong 解析; B 站: popularity)
    /// - 0 表示还没收到 WS 数据
    @Published private(set) var viewerCount: Int = 0

    private var service: AnyObject?
    private var cancellables = Set<AnyCancellable>()
    private var connectImpl: (@MainActor () async -> Void)?
    private var disconnectImpl: (@MainActor () async -> Void)?

    init() {}

    /// 绑定一个 B 站弹幕服务
    func attach(bili: BilibiliDanmakuService) {
        service = bili
        cancellables.removeAll()
        viewerCount = 0
        cancellables.insert(
            bili.$messages
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.messages = $0 }
        )
        cancellables.insert(
            bili.$isConnected
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isConnected = $0 }
        )
        cancellables.insert(
            bili.$popularity
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.viewerCount = $0 }
        )
        connectImpl = { [weak bili] in bili?.connect() }
        disconnectImpl = { [weak bili] in bili?.disconnect() }
    }

    /// 绑定一个抖音弹幕服务
    func attach(douyin: DouyinDanmakuService) {
        service = douyin
        cancellables.removeAll()
        viewerCount = 0
        cancellables.insert(
            douyin.$messages
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.messages = $0 }
        )
        cancellables.insert(
            douyin.$isConnected
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.isConnected = $0 }
        )
        cancellables.insert(
            douyin.$viewerCount
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.viewerCount = $0 }
        )
        connectImpl = { [weak douyin] in await douyin?.connect() }
        disconnectImpl = { [weak douyin] in await douyin?.disconnect() }
    }

    func connect() async {
        await connectImpl?()
    }

    func disconnect() async {
        await disconnectImpl?()
    }
}
