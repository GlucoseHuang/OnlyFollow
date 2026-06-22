import SwiftUI
import SwiftData

/// 播放历史列表（视频历史 + 直播历史）
/// - 顶部 segmented control 切换"视频" / "直播"，跟视频侧整体观感一致
/// - 视频历史：复用 PlaybackHistory（封面/标题/UP主/上次播放进度）
/// - 直播历史：LiveHistory（封面/标题/UP主/进入时间，无 progress 概念）
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaybackHistory.watchedAt, order: .reverse) private var videoEntries: [PlaybackHistory]
    @Query(sort: \LiveHistory.watchedAt, order: .reverse) private var liveEntries: [LiveHistory]
    @State private var segment: Segment = .video
    @Environment(\.dismiss) private var dismiss

    enum Segment: String, CaseIterable, Identifiable {
        case video, live
        var id: String { rawValue }
        var title: String {
            switch self {
            case .video: return "视频"
            case .live: return "直播"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                Group {
                    switch segment {
                    case .video:
                        videoSection
                    case .live:
                        liveSection
                    }
                }
            }
            .navigationTitle("播放历史")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if currentIsEmpty { EditButton().hidden() } else { EditButton() }
                }
            }
        }
    }

    private var currentIsEmpty: Bool {
        switch segment {
        case .video: return videoEntries.isEmpty
        case .live: return liveEntries.isEmpty
        }
    }

    // MARK: - 视频历史

    @ViewBuilder
    private var videoSection: some View {
        if videoEntries.isEmpty {
            ContentUnavailableView(
                "还没有视频播放记录",
                systemImage: "clock.arrow.circlepath",
                description: Text("看完或部分观看过的视频会自动出现在这里")
            )
        } else {
            List {
                ForEach(videoEntries) { entry in
                    Button {
                        PlayerPresenter.present(entry.toVideoItem(), modelContext: modelContext)
                    } label: {
                        HistoryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteVideoEntries)
            }
            .listStyle(.plain)
        }
    }

    private func deleteVideoEntries(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(videoEntries[index])
        }
        modelContext.saveAndKickSync()
    }

    // MARK: - 直播历史

    @ViewBuilder
    private var liveSection: some View {
        if liveEntries.isEmpty {
            ContentUnavailableView(
                "还没有直播观看记录",
                systemImage: "dot.radiowaves.left.and.right",
                description: Text("进入过的直播间会自动出现在这里")
            )
        } else {
            List {
                ForEach(liveEntries) { entry in
                    Button {
                        PlayerPresenter.present(entry.toLiveRoom(), modelContext: modelContext)
                    } label: {
                        LiveHistoryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteLiveEntries)
            }
            .listStyle(.plain)
        }
    }

    private func deleteLiveEntries(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(liveEntries[index])
        }
        modelContext.saveAndKickSync()
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
                    // 多分P视频: 显示 "P5 · 30:00/600:00" 一行,让用户能看出看到哪个分P了
                    if entry.partPage > 0 {
                        Text("·")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("P\(entry.partPage) · \(formatProgress(entry.progressSeconds)) / \(formatProgress(entry.duration))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else if entry.progressSeconds > 0 {
                        Text("·")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text("\(formatProgress(entry.progressSeconds)) / \(formatProgress(entry.duration))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                // 多分P视频: 显示分P标题(如果有),让用户能想起上次看的是哪个分P
                if entry.partPage > 0, !entry.partTitle.isEmpty {
                    Text(entry.partTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

/// 直播历史行：封面 + 标题 + UP主 + 进入时间（无 progress 概念）
/// 视觉上与 HistoryRow 保持一致（封面尺寸、字体、对齐方式）
private struct LiveHistoryRow: View {
    let entry: LiveHistory

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
                Text("直播")
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.red.opacity(0.85))
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
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
