import SwiftUI
import SwiftData

/// 跨博主视频搜索页
/// 设计原则：
/// - 输入即搜索（每次 keystroke 触发一次，async debounce 在 view 层做）
/// - 结果按相关度倒序；展示命中关键词（不强求，简单展示 title + author 即可）
/// - 空状态：未输入 → 显示"输入关键词开始搜索"；输入无果 → 显示"没找到相关视频"
struct VideoSearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var creators: [FollowedCreator]

    @State private var query: String = ""
    @State private var results: [VideoCatalog.SearchResult] = []
    @State private var isSearching = false
    /// 防抖任务：每次 query 变化时取消上一个、再 spawn 新的
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                incompleteHint

                if query.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "搜索所有关注的视频",
                        subtitle: "输入标题关键字或 UP 主名"
                    )
                } else if isSearching && results.isEmpty {
                    ProgressView("搜索中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    emptyState(
                        icon: "questionmark.circle",
                        title: "没找到相关视频",
                        subtitle: "试试更短的关键词，或者先下拉刷新首页让全量数据补齐"
                    )
                } else {
                    resultList
                }
            }
            .navigationTitle("搜索视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 提示状态

    /// 批量拉取进度：(done, total)。nil 表示没有 B 站 creator。
    private var bulkFetchProgress: (done: Int, total: Int)? {
        let bili = creators.filter { $0.platform == "bilibili" }
        guard !bili.isEmpty else { return nil }
        let done = bili.filter { $0.bulkFetchCompletedAt != nil }.count
        return (done, bili.count)
    }

    @ViewBuilder
    private var incompleteHint: some View {
        if let p = bulkFetchProgress, p.done < p.total {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("还有 \(p.total - p.done) 位 UP 主的历史视频未补全，搜索结果暂时不包括它们。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 子视图

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索标题或 UP 主", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: query) { _, new in
                    scheduleSearch(new)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .padding()
    }

    private var resultList: some View {
        List(results) { result in
            SearchResultRow(result: result)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 防抖搜索

    /// query 变化时：取消上一个 debounce、启动 200ms 延迟的搜索
    private func scheduleSearch(_ q: String) {
        debounceTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            isSearching = false
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ q: String) async {
        isSearching = true
        // VideoCatalog.search 是 @MainActor 同步方法，量级可控（≤ 几万条），直接在主线程跑
        let context = modelContext
        let found = VideoCatalog.search(query: q, in: context)
        if !Task.isCancelled {
            results = found
        }
        isSearching = false
    }
}

/// 单条搜索结果
struct SearchResultRow: View {
    let result: VideoCatalog.SearchResult
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            // 走 UIKit 全屏 present，绕开 NavigationLink push 的非全屏问题
            PlayerPresenter.present(result.video, modelContext: modelContext)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: URL(string: result.video.coverURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 140, height: 79)
                .clipShape(.rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill").font(.caption2)
                        Text(result.video.authorName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        Label(formatViewCount(result.video.viewCount), systemImage: "play.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(formatDate(result.video.publishTime), systemImage: "calendar")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text("相关度 \(result.score)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func formatViewCount(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        return "\(n)"
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
