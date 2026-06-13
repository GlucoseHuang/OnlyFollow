import SwiftUI
import SwiftData

struct AddFollowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// 添加成功后调用（已经在主线程，dismiss 之前触发）
    var onAdded: ((FollowedCreator) -> Void)? = nil
    @State private var inputText = ""
    @State private var selectedPlatform: Platform = .bilibili
    @State private var isSearching = false
    @State private var searchResult: FollowedCreator?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("平台") {
                    Picker("平台", selection: $selectedPlatform) {
                        ForEach(Platform.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("添加方式") {
                    TextField("输入 UID 或主页链接", text: $inputText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        searchAndAdd()
                    } label: {
                        HStack {
                            if isSearching { ProgressView() }
                            Text("搜索并添加")
                        }
                    }
                    .disabled(inputText.isEmpty || isSearching)
                }

                if let result = searchResult {
                    Section("搜索结果") {
                        HStack {
                            AsyncImage(url: URL(string: ensureHTTPS(result.avatarURL))) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Color.gray.opacity(0.3)
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())

                            VStack(alignment: .leading) {
                                Text(result.nickname).font(.subheadline.bold())
                                Text(result.platform).font(.caption).foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("添加") {
                                addCreator(result)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("添加关注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func addCreator(_ creator: FollowedCreator) {
        AppLogger.info("Adding creator: uid=\(creator.uid), name=\(creator.nickname), platform=\(creator.platform)")
        modelContext.insert(creator)
        // 立即保存
        try? modelContext.save()
        AppLogger.info("Creator inserted and saved to modelContext")
        // 先回调（让 ContentView 在 sheet 关闭前启动同步），再关闭
        onAdded?(creator)
        dismiss()
    }

    private func searchAndAdd() {
        guard !inputText.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        searchResult = nil

        let uid = extractUID(from: inputText)
        let platform = selectedPlatform

        AppLogger.info("Searching: platform=\(platform.rawValue), uid=\(uid)")

        Task { @MainActor in
            do {
                switch platform {
                case .bilibili:
                    let api = BilibiliAPIService.shared
                    let info = try await api.fetchUserInfo(mid: uid)
                    AppLogger.info("B站用户信息: mid=\(info.mid), name=\(info.name), face=\(info.face.prefix(60))")
                    searchResult = FollowedCreator(
                        uid: "\(info.mid)",
                        platform: "bilibili",
                        nickname: info.name,
                        avatarURL: ensureHTTPS(info.face)
                    )
                case .douyin:
                    errorMessage = "抖音搜索暂未实现，v0.1 仅支持 B 站添加关注"
                }
            } catch {
                AppLogger.error("搜索失败: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func extractUID(from text: String) -> String {
        if let url = URL(string: text), let host = url.host {
            if host.contains("bilibili.com") {
                return url.pathComponents.last ?? text
            }
            if host.contains("douyin.com") {
                return url.pathComponents.last ?? text
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
