import Foundation

/// 抖音直播间 ID 解析工具
///
/// 抖音有两种直播间 ID：
/// - `webcast_id`（用户可见，在直播 URL `https://live.douyin.com/{webcast_id}` 中）
/// - `room_id`（内部数字 ID，WS 连接必须用这个）
///
/// 实测发现：用户主页 live_room 字段返回的 room_id 实际就是 webcast_id（短码），
/// 不是真正的内部 room_id。要拿真正的 room_id，必须调 enter 接口，
/// 然后从响应的 `room.id_str` 字段拿（那是真实的数字 ID）。
///
/// 本类的职责：
/// - 解析 URL 提取 webcast_id
/// - 把任意 ID 走 enter 接口解析为完整 RoomInfo（含真实 room_id + 拉流地址）
struct DouyinLiveRoomInfo {
    let webcastId: String   // 用户可见短码
    let roomId: String     // 内部数字 ID（WS 必须用这个）
    let title: String
    let coverURL: String
    let viewerCount: Int
    let isLiving: Bool
    let flvURL: String?
    let hlsURL: String?
    /// 抖音专属: 每个画质对应的 HLS m3u8 URL
    var hlsURLsByQuality: [String: String] = [:]
    let ownerSecUid: String?
    let ownerNickname: String?
    let ownerAvatarURL: String?

    /// 从 LiveRoom API 响应构造
    static func from(_ resp: DouyinLiveRoomResponse) -> DouyinLiveRoomInfo {
        let r = resp.room
        let stream = r?.streamURL
        // HLS URL 优先级: map 里的最高画质 > 单 string 字段 > nil
        // 抖音 web 端 HLS 实际在 hls_pull_url_map (Dict),hls_pull_url 是旧字段
        let hlsURL: String? = {
            if let map = stream?.hlsPullUrlMap {
                return map["FULL_HD1"] ?? map["HD1"] ?? map["SD1"] ?? map["SD2"] ?? map.values.first
            }
            return stream?.hlsPullURL
        }()
        // 画质字典: enter 接口给的是 hls_pull_url_map, sdk_key-style key
        // 这里的 map key 是 FULL_HD1/HD1/SD1/SD2 (不是 ld/sd/hd/uhd/origin), 与 user profile 不同
        // 留空,画质切换 UI 在 user profile 成功时不依赖这里
        return DouyinLiveRoomInfo(
            webcastId: r?.idStr ?? "",
            roomId: r?.idStr ?? "",
            title: r?.title ?? "",
            coverURL: r?.coverURL ?? "",
            viewerCount: r?.userCount ?? 0,
            isLiving: r?.status == 2,
            flvURL: stream?.flvPullURL,
            hlsURL: hlsURL,
            hlsURLsByQuality: [:],
            ownerSecUid: resp.user?.secUid,
            ownerNickname: resp.user?.nickname,
            ownerAvatarURL: resp.user?.avatarURL
        )
    }

    /// 转为项目内部的 LiveRoom（VideoPlayerView 用这个）
    func toLiveRoom() -> LiveRoom {
        var room = LiveRoom(
            id: roomId,
            roomID: roomId,
            title: title,
            coverURL: coverURL,
            streamURL: hlsURL ?? flvURL ?? "",
            viewerCount: viewerCount,
            authorUID: ownerSecUid ?? "",
            authorName: ownerNickname ?? "",
            authorAvatar: ownerAvatarURL ?? "",
            platform: "douyin",
            isLive: isLiving
        )
        room.hlsURLsByQuality = hlsURLsByQuality
        return room
    }

    /// 从 URL 提取 webcast_id
    /// - 支持格式：`https://live.douyin.com/{id}`, `https://webcast-open.douyin.com/...`
    /// - 返回 nil 表示解析失败
    static func parseWebcastId(from urlOrId: String) -> String? {
        let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已经是纯数字 ID（19 位左右）
        if trimmed.allSatisfy({ $0.isNumber }) {
            return trimmed
        }
        // URL 解析
        if let url = URL(string: trimmed), let host = url.host {
            if host.contains("douyin.com") {
                let last = url.pathComponents.last(where: { $0 != "/" })
                return last
            }
        }
        return nil
    }
}
