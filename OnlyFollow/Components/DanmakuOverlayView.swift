import SwiftUI

/// 弹幕叠加层 —— 简单滚动文本显示
/// 后续可升级为逐条飘过的 Canvas 渲染
struct DanmakuOverlayView: View {
    let messages: [DanmakuMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(messages.suffix(30)) { msg in
                        Text(msg.content)
                            .font(.caption)
                            .foregroundStyle(colorFromHex(msg.color))
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .id(msg.id)
                    }
                }
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: 120)
        .padding(.horizontal, 8)
    }

    private func colorFromHex(_ hex: UInt32) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}
