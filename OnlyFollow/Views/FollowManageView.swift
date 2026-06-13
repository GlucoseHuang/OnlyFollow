import SwiftUI
import SwiftData

struct FollowManageView: View {
    @Query(sort: \FollowedCreator.addedAt, order: .reverse) private var creators: [FollowedCreator]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            ForEach(creators) { creator in
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: creator.avatarURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.3)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(creator.nickname)
                            .font(.subheadline)
                        Text(creator.platform)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        modelContext.delete(creator)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("管理关注")
        .navigationBarTitleDisplayMode(.inline)
    }
}
