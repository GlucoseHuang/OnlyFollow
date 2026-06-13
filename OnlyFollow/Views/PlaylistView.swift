import SwiftUI
import SwiftData

/// 播放列表页面
/// - 显示所有 PlaylistItem，按 order 升序
/// - 点击任意一个进入播放（自动按顺序播完）
/// - 顺序/倒序轮播
struct PlaylistView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PlaylistItem.order) private var items: [PlaylistItem]
    @State private var sortAscending: Bool = true
    @State private var playingItem: PlaylistItem?
    @State private var startingIndex: Int = 0
    @Environment(\.dismiss) private var dismiss

    private var sortedItems: [PlaylistItem] {
        sortAscending ? items : items.reversed()
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "播放列表为空",
                        systemImage: "list.bullet.rectangle",
                        description: Text("在 UP 主详情页左滑视频可加入播放列表")
                    )
                } else {
                    List {
                        Section {
                            ForEach(Array(sortedItems.enumerated()), id: \.element.id) { idx, item in
                                Button {
                                    playingItem = item
                                    startingIndex = idx
                                } label: {
                                    PlaylistRow(item: item, index: idx + 1)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteItems)
                            .onMove(perform: moveItems)
                        } header: {
                            HStack {
                                Text("共 \(items.count) 个视频")
                                Spacer()
                                Button {
                                    sortAscending.toggle()
                                } label: {
                                    Label(sortAscending ? "顺序" : "倒序",
                                          systemImage: sortAscending ? "arrow.up" : "arrow.down")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("播放列表")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                if !items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
            }
            .fullScreenCover(item: $playingItem) { item in
                VideoPlayerView(
                    video: item.toVideoItem(),
                    modelContext: modelContext,
                    playlist: sortedItems.map { $0.toVideoItem() },
                    playlistStartIndex: startingIndex
                )
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let target = sortedItems
        for index in offsets {
            modelContext.delete(target[index])
        }
        try? modelContext.save()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        var reordered = sortedItems
        reordered.move(fromOffsets: source, toOffset: destination)
        for (idx, item) in reordered.enumerated() {
            item.order = idx
        }
        try? modelContext.save()
    }
}

private struct PlaylistRow: View {
    let item: PlaylistItem
    let index: Int
    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            AsyncImage(url: URL(string: item.coverURL)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.gray.opacity(0.2) }
            .frame(width: 110, height: 65)
            .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }
}
