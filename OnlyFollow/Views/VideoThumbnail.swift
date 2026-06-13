import SwiftUI
import SwiftData

struct VideoThumbnail: View {
    let video: VideoItem
    /// 从父 SwiftUI 环境拿 modelContext，传给 PlayerPresenter；
    /// 不传的话独立 UIHostingController 里 @Environment(\.modelContext) 不可靠，历史/收藏会失效
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            PlayerPresenter.present(video, modelContext: modelContext)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: URL(string: video.coverURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 140, height: 90)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text(formatDuration(video.duration))
                        .font(.caption2).bold()
                        .padding(.horizontal, 4)
                        .background(.black.opacity(0.7))
                        .clipShape(.rect(cornerRadius: 4))
                        .padding(4)
                }

                Text(video.title)
                    .font(.caption2)
                    .lineLimit(2)
                    .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
