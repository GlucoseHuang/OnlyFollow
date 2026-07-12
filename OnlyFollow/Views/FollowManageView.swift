import SwiftUI
import SwiftData

struct FollowManageView: View {
    @Query(sort: \FollowedCreator.addedAt, order: .reverse) private var creators: [FollowedCreator]
    @Environment(\.modelContext) private var modelContext

    /// 待二次确认的 creator(非 nil 时显示弹窗)
    @State private var pendingUnfollow: FollowedCreator?
    @State private var unfollowCounts: UnfollowService.RetainedCounts?

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
                        // 先统计要保留 / 删除的条目数,弹窗展示给用户
                        unfollowCounts = UnfollowService.countRetained(uid: creator.uid, in: modelContext)
                        pendingUnfollow = creator
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("管理关注")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingUnfollow.map { "确定要取消关注「\($0.nickname)」吗？" } ?? "",
            isPresented: Binding(
                get: { pendingUnfollow != nil },
                set: { newValue in
                    if !newValue {
                        pendingUnfollow = nil
                        unfollowCounts = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("取消关注", role: .destructive) {
                if let creator = pendingUnfollow {
                    UnfollowService.unfollow(creator, in: modelContext)
                }
                pendingUnfollow = nil
                unfollowCounts = nil
            }
            Button("再想想", role: .cancel) {
                pendingUnfollow = nil
                unfollowCounts = nil
            }
        } message: {
            Text(dialogMessage)
        }
    }

    private var dialogMessage: String {
        guard let counts = unfollowCounts else {
            return "将从首页移除该 UP 主。"
        }
        return UnfollowService.dialogMessage(for: counts)
    }
}
