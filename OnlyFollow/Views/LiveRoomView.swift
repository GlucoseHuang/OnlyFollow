import SwiftUI

struct LiveRoomView: View {
    let room: LiveRoom
    @StateObject private var danmakuService: BilibiliDanmakuService
    @State private var playerURL: URL?
    @Environment(\.dismiss) private var dismiss

    init(room: LiveRoom) {
        self.room = room
        // 初始化弹幕服务（B站）
        _danmakuService = StateObject(wrappedValue: BilibiliDanmakuService(
            roomID: Int(room.roomID) ?? 0,
            token: "",
            host: ""
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let url = playerURL {
                    VideoPlayerWrapper(url: url)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 16) {
                        ProgressView().tint(.white)
                        Text("连接直播间...")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                // 弹幕叠加层
                VStack {
                    Spacer()
                    DanmakuOverlayView(messages: danmakuService.messages)
                }
                .allowsHitTesting(false)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("退出") { dismiss() }
                        .tint(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if danmakuService.isConnected {
                            Circle().fill(.green).frame(width: 8, height: 8)
                        }
                        Text("👁 \(room.viewerCount)")
                            .font(.caption)
                    }
                    .tint(.white)
                }
            }
            .task {
                await connectLiveAndDanmaku()
            }
            .onDisappear {
                danmakuService.disconnect()
            }
        }
    }

    private func connectLiveAndDanmaku() async {
        // 1. 获取直播流地址
        if room.streamURL.hasPrefix("http") {
            playerURL = URL(string: room.streamURL)
        }

        // 2. 连接弹幕（仅 B 站）
        if room.platform == "bilibili" {
            // TODO: 先获取 danmuInfo，再连接
            // danmakuService.connect()
        }
    }
}
