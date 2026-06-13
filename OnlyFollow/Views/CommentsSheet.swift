import SwiftUI

/// 评论列表（半屏 sheet）
/// - 调 /x/v2/reply/wbi/main 拿分页（必须 WBI 签名）
struct CommentsSheet: View {
    let aid: String
    @State private var comments: [BilibiliComment] = []
    @State private var isLoading = false
    @State private var error: String?
    /// 翻页用 cursor；B站新版评论区使用 `next_offset` 作为下一次 pagination_str 的 offset
    @State private var nextOffset: String = ""
    @State private var hasMore = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && comments.isEmpty {
                    ProgressView("加载评论中...")
                } else if let err = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    .padding()
                } else if comments.isEmpty {
                    ContentUnavailableView("暂无评论", systemImage: "ellipsis.bubble")
                } else {
                    List {
                        ForEach(comments, id: \.id) { c in
                            CommentRow(c: c)
                        }
                        if hasMore {
                            HStack {
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                } else {
                                    Button("加载更多") {
                                        Task { await loadMore() }
                                    }
                                    .font(.caption)
                                }
                                Spacer()
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("评论")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await loadMore() }
    }

    private func loadMore() async {
        if isLoading || !hasMore { return }
        isLoading = true
        error = nil
        do {
            let result = try await BilibiliAPIService.shared.fetchVideoCommentsWithCursor(
                aid: aid, offset: nextOffset
            )
            comments.append(contentsOf: result.replies)
            nextOffset = result.nextOffset
            hasMore = !result.nextOffset.isEmpty
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

private struct CommentRow: View {
    let c: BilibiliComment
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: URL(string: ensureHTTPS(c.member.avatar ?? ""))) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.gray.opacity(0.3) }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(c.member.uname ?? "匿名用户").font(.caption.bold()).foregroundStyle(.secondary)
                Text(c.content.message).font(.callout)
                HStack(spacing: 10) {
                    if let ctime = c.ctime {
                        Text(formatTimeAgo(ctime))
                    }
                    if let like = c.like, like > 0 {
                        Label("\(like)", systemImage: "hand.thumbsup")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTimeAgo(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
