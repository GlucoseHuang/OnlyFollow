import Foundation

struct DanmakuMessage: Identifiable, Sendable {
    let id: UUID
    let content: String
    let color: UInt32
    let senderName: String
    let timestamp: Date

    init(content: String, color: UInt32 = 0xFFFFFF, senderName: String = "", timestamp: Date = .now) {
        self.id = UUID()
        self.content = content
        self.color = color
        self.senderName = senderName
        self.timestamp = timestamp
    }
}
