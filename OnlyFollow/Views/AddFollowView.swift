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
        modelContext.saveAndKickSync()
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
                    // 抖音 fetchUserInfo 只接受 sec_user_id（以 MS4w 开头的长串）
                    // 数字形式的“抖音号”（unique_id，如 88805309602）需要先走搜索接口转 sec_uid
                    // v0.1 暂不支持该转换，提示用户
                    guard uid.hasPrefix("MS4w") else {
                        throw DouyinAPIError.parseError("需要粘贴抖音主页链接或 sec_user_id（数字抖音号暂不支持，请用浏览器打开主播主页拷贝 URL）")
                    }
                    let api = DouyinAPIService.shared
                    let info = try await api.fetchUserInfo(secUid: uid)
                    AppLogger.info("抖音用户信息: nickname=\(info.nickname ?? "<nil>"), secUid=\(info.secUid?.prefix(12) ?? "<nil>")..., fans=\(info.followerCount ?? 0)")
                    searchResult = FollowedCreator(
                        uid: info.secUid ?? uid,
                        platform: "douyin",
                        nickname: info.nickname ?? uid,
                        avatarURL: ensureHTTPS(info.avatarURL ?? "")
                    )
                }
            } catch {
                AppLogger.error("搜索失败: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func extractUID(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // URL 解析（提取末段作为 sec_user_id 或 mid）
        if let url = URL(string: trimmed), let host = url.host {
            if host.contains("bilibili.com") {
                return url.pathComponents.last ?? trimmed
            }
            if host.contains("douyin.com") {
                // 抖音 URL 形如 https://www.douyin.com/user/{sec_uid}
                // 末段就是 sec_uid（MS4wLjAB... 开头的长串）
                let last = url.pathComponents.last ?? trimmed
                if last.hasPrefix("MS4w") { return last }
                // 末段不是 sec_uid 格式，说明 URL 形如 /video/{aweme_id} 或 /note/{id} 或短链
                // 这种情况下无法直接拿到 sec_uid，留给调用方处理
                return last
            }
        }
        // 纯字符串
        if trimmed.hasPrefix("MS4w") {
            // 是 sec_user_id（B 站 mid 一般是纯数字）
            return trimmed
        }
        return trimmed
    }
}
