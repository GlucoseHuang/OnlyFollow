import SwiftUI
import SwiftData

/// 播放历史列表（按 watchedAt 倒序）
/// 每行展示：封面 / 标题 / UP主 / 几月几日几时几分 / 上次播放进度
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaybackHistory.watchedAt, order: .reverse) private var entries: [PlaybackHistory]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "还没有播放记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("看完或部分观看过的视频会自动出现在这里")
                    )
                } else {
                    List {
                        ForEach(entries) { entry in
                            NavigationLink {
                                VideoPlayerView(video: entry.toVideoItem(), modelContext: modelContext)
                            } label: {
                                HistoryRow(entry: entry)
                            }
                        }
                        .onDelete(perform: deleteEntries)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("播放历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
            }
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(entries[index])
        }
        try? modelContext.save()
    }
}

private struct HistoryRow: View {
    let entry: PlaybackHistory

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: entry.coverURL)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.gray.opacity(0.2) }
            .frame(width: 120, height: 70)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                Text(formatDuration(entry.duration))
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 3))
                    .padding(3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: entry.watchedAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if entry.progressSeconds > 0 {
                        Text("·")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("\(formatProgress(entry.progressSeconds)) / \(formatProgress(entry.duration))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func formatProgress(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
