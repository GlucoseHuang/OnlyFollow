import SwiftUI
import WebKit
import UIKit

/// 抖音扫码登录视图
///
/// 跟 B 站 LoginView 的差异：
/// - B 站是 URLSession 生成 QR 码数据 → CIImage 渲染
/// - 抖音是直接展示一个 WKWebView，让抖音自己的 JS 渲染二维码 UI
struct DouyinLoginView: View {
    @Binding var isPresented: Bool
    @State private var status: DouyinLoginService.LoginStatus = .loading
    @State private var webView: WKWebView?
    @State private var countdown: Int = 0
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                webViewSection
                statusSection
                helpSection
            }
            .padding()
            .navigationTitle("登录抖音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { close() }
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
            DouyinLoginService.shared.stop()
        }
        .onAppear { start() }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var webViewSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
                .frame(width: 280, height: 360)
            if case .success = status {
                // 登录成功后的提示
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("登录成功")
                        .font(.headline)
                    Text("抖音 cookie 已保存，下一次刷新视频列表就会拉到内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else if let webView {
                WebViewContainer(webView: webView)
                    .frame(width: 260, height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载抖音登录页…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 6) {
            statusText
                .font(.callout)
                .foregroundStyle(statusColor)
            if countdown > 0 {
                Text("\(countdown)s 后自动关闭")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusText: Text {
        switch status {
        case .idle: return Text("准备中…")
        case .loading: return Text("正在打开抖音登录页…")
        case .showingQR: return Text("请使用抖音 手机 App 扫描上方二维码")
        case .scanned: return Text("已扫码，请在手机上点击确认登录")
        case .success: return Text("登录成功")
        case .expired: return Text("二维码已过期")
        case .error(let msg): return Text(msg)
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle, .loading, .showingQR: return .secondary
        case .scanned, .expired: return .orange
        case .success: return .green
        case .error: return .red
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("打开抖音 手机 App", systemImage: "1.circle")
            Label("点击左上角扫一扫", systemImage: "2.circle")
            Label("扫描上方二维码并点击确认登录", systemImage: "3.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - 流程

    private func start() {
        // 注册状态回调
        DouyinLoginService.shared.onStatusChange = { newStatus in
            Task { @MainActor in
                status = newStatus
                if case .success = newStatus {
                    // 登录成功后 1.5s 自动关闭 sheet,让上层弹一个 toast
                    pollTask?.cancel()
                    pollTask = Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        if !Task.isCancelled {
                            isPresented = false
                        }
                    }
                }
            }
        }
        // 启动 WebView
        DouyinLoginService.shared.start { wv in
            self.webView = wv
        }
    }

    private func close() {
        pollTask?.cancel()
        DouyinLoginService.shared.stop()
        isPresented = false
    }
}

/// UIKit WebView 的 SwiftUI 包装
private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
