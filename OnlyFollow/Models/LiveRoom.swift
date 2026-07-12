import Foundation

/// 项目内部的直播间模型（跨平台通用）
/// - 抖音: streamURL 存 HLS (m3u8) 入口, hlsURLsByQuality 存所有画质 HLS URL（key 是 sdk_key: ld/sd/hd/uhd/origin）
/// - B 站: streamURL 存 FLV 入口（AVPlayer 兼容）
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
    /// 抖音专属：每个画质对应的 HLS m3u8 URL。key 是 sdk_key (ld/sd/hd/uhd/origin)。
    /// 平台非抖音时为空。画质选择 UI 用这个。
    var hlsURLsByQuality: [String: String] = [:]
}
