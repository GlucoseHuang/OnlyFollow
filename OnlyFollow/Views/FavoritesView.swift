import SwiftUI
import SwiftData

/// 收藏夹页面
struct FavoritesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteVideo.addedAt, order: .reverse) private var favorites: [FavoriteVideo]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableView(
                        "还没有收藏",
                        systemImage: "star",
                        description: Text("在播放页点右上角的 ⭐ 即可收藏视频")
                    )
                } else {
                    List {
                        ForEach(favorites) { fav in
                            NavigationLink {
                                VideoPlayerView(video: fav.toVideoItem(), modelContext: modelContext)
                            } label: {
                                FavoriteRow(fav: fav)
                            }
                        }
                        .onDelete(perform: deleteFavorites)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("我的收藏")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                if !favorites.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
            }
        }
    }

    private func deleteFavorites(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(favorites[index])
        }
        try? modelContext.save()
    }
}

private struct FavoriteRow: View {
    let fav: FavoriteVideo
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: fav.coverURL)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.gray.opacity(0.2) }
            .frame(width: 120, height: 70)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                Text(formatDuration(fav.duration))
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 3))
                    .padding(3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(fav.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(fav.authorName).font(.caption).foregroundStyle(.secondary)
                    Label(formatViewCount(fav.viewCount), systemImage: "play.rectangle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("收藏于 \(formatAddedAt(fav.addedAt))")
                    .font(.caption2).foregroundStyle(.tertiary)
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

    private func formatViewCount(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        return String(n)
    }

    private func formatAddedAt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
