import SwiftUI
import UIKit

/// B 站二维码登录视图
struct LoginView: View {
    @Binding var isPresented: Bool
    @State private var qrImage: UIImage?
    @State private var qrcodeKey: String = ""
    @State private var status: BilibiliLoginService.LoginStatus = .waiting
    @State private var pollTask: Task<Void, Never>?
    @State private var isGenerating = false
    @State private var countdown: Int = 0

    private let pollInterval: TimeInterval = 2.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                qrSection
                statusSection
                actionsSection
                helpSection
            }
            .padding()
            .navigationTitle("登录 B站")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { close() }
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var qrSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
                .frame(width: 240, height: 240)
            if let img = qrImage, case .expired = status {
                // 二维码过期
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("二维码已过期").font(.subheadline)
                }
            } else if let img = qrImage {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
            } else if isGenerating {
                ProgressView()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
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
                Text("\(countdown)s 后刷新")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusText: Text {
        switch status {
        case .waiting: return Text("请使用 B站 手机 App 扫描二维码")
        case .scanned: return Text("已扫码，请在手机上点击确认")
        case .success: return Text("登录成功")
        case .expired: return Text("二维码已过期")
        case .error(let msg): return Text(msg)
        }
    }

    private var statusColor: Color {
        switch status {
        case .waiting: return .secondary
        case .scanned: return .orange
        case .success: return .green
        case .expired: return .orange
        case .error:    return .red
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button {
                Task { await regenerate() }
            } label: {
                Label("刷新二维码", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isGenerating)
        }
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("打开 B站 手机 App", systemImage: "1.circle")
            Label("点击左上角扫码", systemImage: "2.circle")
            Label("扫描上方二维码并确认登录", systemImage: "3.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    // MARK: - 流程

    private func regenerate() async {
        pollTask?.cancel()
        isGenerating = true
        status = .waiting
        qrImage = nil
        qrcodeKey = ""
        do {
            let result = try await BilibiliLoginService.shared.generate()
            qrcodeKey = result.qrcodeKey
            qrImage = result.image
            startPolling()
        } catch {
            AppLogger.error("LoginView: generate failed: \(error.localizedDescription)")
            status = .error("二维码生成失败，请重试")
        }
        isGenerating = false
    }

    private func startPolling() {
        let key = qrcodeKey
        guard !key.isEmpty else { return }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                let result = await BilibiliLoginService.shared.poll(qrcodeKey: key)
                await MainActor.run {
                    handleStatus(result)
                }
                if Task.isCancelled { break }
                if case .success(let cookies) = result {
                    await handleSuccess(cookies: cookies)
                    break
                }
                if case .expired = result { break }
                if case .error = result {
                    try? await Task.sleep(for: .seconds(pollInterval))
                    continue
                }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    private func handleStatus(_ result: BilibiliLoginService.LoginStatus) {
        status = result
        if case .expired = result {
            // 二维码过期，启动 30s 倒计时后自动刷新
            countdown = 30
            Task {
                while countdown > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    countdown -= 1
                }
                if !Task.isCancelled, case .expired = status {
                    await regenerate()
                }
            }
        }
    }

    private func handleSuccess(cookies: [String: String]) async {
        // 关键 cookie 缺失提示
        guard cookies["SESSDATA"] != nil else {
            status = .error("登录响应未含 SESSDATA，请重试")
            return
        }
        BilibiliSessionManager.shared.saveLoginCookies(cookies)
        // 关闭 sheet
        try? await Task.sleep(for: .milliseconds(600))
        isPresented = false
    }

    private func close() {
        pollTask?.cancel()
        isPresented = false
    }
}
