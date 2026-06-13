import SwiftUI

struct CreatorCard: View {
    let creator: FollowedCreator
    let videos: [VideoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: creator.avatarURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())

                Text(creator.nickname)
                    .font(.subheadline.bold())

                Spacer()

                NavigationLink {
                    CreatorDetailView(creator: creator)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !videos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(videos.prefix(5)) { video in
                            VideoThumbnail(video: video)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}
