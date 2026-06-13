import SwiftUI

struct SettingsView: View {
    @State private var bilibiliCookie = AppSettings.bilibiliCookie
    @State private var showCookieHelp = false
    @State private var showQRLogin = false
    @State private var loginState: BilibiliLoginState = .unknown
    @State private var showAdvanced = false

    var body: some View {
        Form {
            loginSection
            advancedToggleSection
            if showAdvanced {
                advancedSection
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showQRLogin) {
            LoginView(isPresented: $showQRLogin)
        }
        .task {
            loginState = await BilibiliSessionManager.shared.verifyLogin()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: BilibiliSessionManager.loginStateDidChangeNotification)
                .receive(on: RunLoop.main)
        ) { note in
            if let state = note.object as? BilibiliLoginState {
                loginState = state
                bilibiliCookie = AppSettings.bilibiliCookie
            }
        }
    }

    // MARK: - 登录态

    private var loginSection: some View {
        Section {
            HStack {
                Image(systemName: loginIconName)
                    .font(.title2)
                    .foregroundStyle(loginIconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loginTitle).font(.subheadline.bold())
                    Text(loginSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .loggedIn = loginState {
                    Button("退出登录") {
                        BilibiliSessionManager.shared.logout()
                        loginState = .loggedOut
                    }
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }

            Button {
                showQRLogin = true
            } label: {
                Label("扫码登录 B站", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        } header: {
            Text("B站登录")
        } footer: {
            Text(loginFooter)
        }
    }

    private var advancedToggleSection: some View {
        Section {
            Button {
                withAnimation { showAdvanced.toggle() }
            } label: {
                HStack {
                    Label("高级：手动粘贴 Cookie", systemImage: "chevron.right.square")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 子视图

    private var loginIconName: String {
        switch loginState {
        case .loggedIn: return "person.crop.circle.fill.badge.checkmark"
        case .loggedOut: return "person.crop.circle.badge.exclamationmark"
        case .unknown: return "person.crop.circle"
        }
    }

    private var loginIconColor: Color {
        switch loginState {
        case .loggedIn: return .green
        case .loggedOut: return .orange
        case .unknown: return .secondary
        }
    }

    private var loginTitle: String {
        switch loginState {
        case .loggedIn(_, let name): return name.isEmpty ? "已登录" : name
        case .loggedOut: return "未登录"
        case .unknown: return "验证中…"
        }
    }

    private var loginSubtitle: String {
        switch loginState {
        case .loggedIn(_, let name):
            if !name.isEmpty, AppSettings.bilibiliLoggedUID != 0 {
                return "UID: \(AppSettings.bilibiliLoggedUID) · 已保存登录态"
            }
            return "已保存登录态"
        case .loggedOut:
            return AppSettings.hasBilibiliCookie
                ? "Cookie 存在但验证未通过，可能已失效"
                : "未登录时请求易被限流"
        case .unknown:
            return ""
        }
    }

    private var loginFooter: String {
        switch loginState {
        case .loggedIn: return "登录态会持久保存，失效时自动提示重新登录"
        case .loggedOut: return "扫码登录后即可正常浏览所有内容；如扫码不便可展开高级选项手动粘贴 Cookie"
        case .unknown: return "正在验证登录态…"
        }
    }

    // MARK: - 高级（手动 Cookie）

    private var advancedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $bilibiliCookie)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .background(.gray.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 8))

                HStack {
                    Button("保存") {
                        AppSettings.bilibiliCookie = bilibiliCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                        BilibiliSessionManager.shared.reset()
                        Task {
                            loginState = await BilibiliSessionManager.shared.verifyLogin(force: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bilibiliCookie.trimmingCharacters(in: .whitespacesAndNewlines) == AppSettings.bilibiliCookie)

                    Button("清除") {
                        bilibiliCookie = ""
                        AppSettings.bilibiliCookie = ""
                        BilibiliSessionManager.shared.logout()
                        loginState = .loggedOut
                    }
                    .foregroundStyle(.red)

                    Spacer()

                    Button("如何获取？") {
                        showCookieHelp = true
                    }
                }
            }
        } header: {
            Text("手动 Cookie")
        } footer: {
            Text("仅在扫码不可用时使用。关键字段：SESSDATA。")
                .font(.caption2)
        }
        .alert("如何获取 B站 Cookie", isPresented: $showCookieHelp) {
            Button("知道了") {}
        } message: {
            Text("1. 在电脑浏览器打开 bilibili.com 并登录\n2. 按 F12 打开开发者工具\n3. 切换到 Network 标签\n4. 刷新页面，点击任意请求\n5. 在请求头中找到 Cookie 字段\n6. 复制整个 Cookie 值粘贴到上方\n\n关键要包含 SESSDATA 字段")
        }
    }
}
