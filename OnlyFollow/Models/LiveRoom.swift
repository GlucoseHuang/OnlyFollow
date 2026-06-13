import Foundation

struct LiveRoom: Identifiable, Codable, Sendable {
    let id: String
    let roomID: String
    let title: String
    let coverURL: String
    let streamURL: String
    let viewerCount: Int
    let authorUID: String
    let authorName: String
    let authorAvatar: String
    let platform: String
    let isLive: Bool
}
