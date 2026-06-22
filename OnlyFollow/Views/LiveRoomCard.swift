import SwiftUI
import SwiftData

struct LiveRoomCard: View {
    let room: LiveRoom
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            // 走 UIKit 全屏 present，跟视频侧 PlayerPresenter 一致
            PlayerPresenter.present(room, modelContext: modelContext)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: room.authorAvatar)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(room.authorName)
                        .font(.subheadline.bold())
                    Text(room.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "eye")
                    Text("\(room.viewerCount)")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
