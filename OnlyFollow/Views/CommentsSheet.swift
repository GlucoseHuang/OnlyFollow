import SwiftUI

/// 评论列表（半屏 sheet）
/// - 调 /x/v2/reply/wbi/main 拿分页（必须 WBI 签名）
struct CommentsSheet: View {
    /// 视频 ID：B 站是 aid（字符串化的 Int），抖音是 aweme_id（字符串形式的数字）
    let videoId: String
    /// 平台: "bilibili" | "douyin"
    let platform: String
    @State private var comments: [AnyComment] = []
    @State private var isLoading = false
    @State private var error: String?
    /// 翻页用 cursor；B站新版评论区使用 `next_offset` 作为下一次 pagination_str 的 offset
    @State private var nextOffset: String = ""
    @State private var nextCursor: Int = 0
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
                        ForEach(comments.indices, id: \.self) { idx in
                            CommentRow(any: comments[idx])
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
            switch platform {
            case "bilibili":
                let result = try await BilibiliAPIService.shared.fetchVideoCommentsWithCursor(
                    aid: videoId, offset: nextOffset
                )
                comments.append(contentsOf: result.replies.map { AnyComment($0) })
                nextOffset = result.nextOffset
                hasMore = !result.nextOffset.isEmpty
            case "douyin":
                let result = try await DouyinAPIService.shared.fetchVideoComments(
                    awemeId: videoId, cursor: nextCursor
                )
                comments.append(contentsOf: result.comments.map { AnyComment($0) })
                nextCursor = result.cursor ?? 0
                hasMore = result.hasMore ?? false
            default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

private struct CommentRow: View {
    let any: AnyComment
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 根据底层类型 dispatch
            if let bili = any.bili {
                AsyncImage(url: URL(string: ensureHTTPS(bili.member.avatar ?? ""))) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.gray.opacity(0.3) }
                .frame(width: 36, height: 36).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(bili.member.uname ?? "匿名用户").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(bili.content.message).font(.callout)
                    HStack(spacing: 10) {
                        if let ctime = bili.ctime { Text(formatTimeAgo(ctime)) }
                        if let like = bili.like, like > 0 { Label("\(like)", systemImage: "hand.thumbsup") }
                    }.font(.caption2).foregroundStyle(.tertiary)
                }
            } else if let dy = any.dy {
                let dyUser = dy.user
                AsyncImage(url: URL(string: ensureHTTPS(dyUser?.avatarURL ?? ""))) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.gray.opacity(0.3) }
                .frame(width: 36, height: 36).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(dyUser?.nickname ?? "匿名用户").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(dy.text ?? "").font(.callout)
                    HStack(spacing: 10) {
                        Text(formatTimeAgo(dy.createTime ?? 0))
                        Label("\(dy.diggCount ?? 0)", systemImage: "hand.thumbsup")
                    }.font(.caption2).foregroundStyle(.tertiary)
                }
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


// MARK: - 跨平台评论包装

/// 平台无关的评论包装：CommentsSheet 的 [State] 用这个数组，避免在 sheet 里同时塞两种具体类型
struct AnyComment: Identifiable {
    let bili: BilibiliComment?
    let dy: DouyinComment?

    var id: String {
        bili?.idString ?? dy?.id ?? UUID().uuidString
    }

    init(_ bili: BilibiliComment) {
        self.bili = bili
        self.dy = nil
    }
    init(_ dy: DouyinComment) {
        self.bili = nil
        self.dy = dy
    }
}
