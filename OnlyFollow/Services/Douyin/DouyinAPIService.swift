import Foundation

actor DouyinAPIService {
    private let session = URLSession.shared
    private let webBaseURL = "https://www.douyin.com"

    // MARK: - User Info

    func fetchUserInfo(uid: String, cookies: String, signatures: DouyinSignatures) async throws -> DouyinUserInfo {
        var components = URLComponents(string: "\(webBaseURL)/aweme/v1/web/user/profile/")!
        components.queryItems = [
            URLQueryItem(name: "uid", value: uid),
            URLQueryItem(name: "X-Bogus", value: signatures.xBogus),
        ]
        let url = components.url!
        var request = URLRequest(url: url)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue(webBaseURL, forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(DouyinUserInfo.self, from: data)
    }

    // MARK: - User Videos

    func fetchUserVideos(uid: String, cookies: String, signatures: DouyinSignatures, cursor: Int = 0) async throws -> [VideoItem] {
        var components = URLComponents(string: "\(webBaseURL)/aweme/v1/web/aweme/post/")!
        components.queryItems = [
            URLQueryItem(name: "sec_user_id", value: uid),
            URLQueryItem(name: "max_cursor", value: "\(cursor)"),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "X-Bogus", value: signatures.xBogus),
        ]
        let url = components.url!
        var request = URLRequest(url: url)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue(webBaseURL, forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(DouyinVideoListResponse.self, from: data)
        return response.awemeList.map { $0.toVideoItem() }
    }

    // MARK: - Live Room

    func fetchLiveRoom(roomID: String, cookies: String) async throws -> LiveRoom {
        let url = URL(string: "\(webBaseURL)/webcast/room/web/enter/?app_name=douyin_web&room_id=\(roomID)")!
        var request = URLRequest(url: url)
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue(webBaseURL, forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(DouyinLiveRoomResponse.self, from: data)
        return response.toLiveRoom()
    }
}

// MARK: - Supporting Types

struct DouyinSignatures: Sendable {
    let xBogus: String
    let msToken: String
}

struct DouyinUserInfo: Codable, Sendable {
    let nickname: String
    let avatarThumb: AvatarURL
    let followerCount: Int
    let awemeCount: Int

    struct AvatarURL: Codable, Sendable {
        let urlList: [String]
        enum CodingKeys: String, CodingKey { case urlList = "url_list" }
    }

    enum CodingKeys: String, CodingKey {
        case nickname
        case avatarThumb = "avatar_thumb"
        case followerCount = "follower_count"
        case awemeCount = "aweme_count"
    }
}

struct DouyinVideoListResponse: Codable, Sendable {
    let awemeList: [DouyinVideoItem]
    enum CodingKeys: String, CodingKey { case awemeList = "aweme_list" }
}

struct DouyinVideoItem: Codable, Sendable {
    let awemeID: String
    let desc: String
    let cover: CoverURL
    let video: VideoInfo
    let author: AuthorInfo
    let statistics: Statistics

    struct CoverURL: Codable, Sendable {
        let urlList: [String]
        enum CodingKeys: String, CodingKey { case urlList = "url_list" }
    }

    struct VideoInfo: Codable, Sendable {
        let playAddr: PlayAddr
        let duration: Int

        struct PlayAddr: Codable, Sendable {
            let urlList: [String]
            enum CodingKeys: String, CodingKey { case urlList = "url_list" }
        }

        enum CodingKeys: String, CodingKey {
            case playAddr = "play_addr"
            case duration
        }
    }

    struct AuthorInfo: Codable, Sendable {
        let uid: String
        let nickname: String
        let avatarThumb: CoverURL
        enum CodingKeys: String, CodingKey {
            case uid, nickname
            case avatarThumb = "avatar_thumb"
        }
    }

    struct Statistics: Codable, Sendable {
        let playCount: Int
        let commentCount: Int
        enum CodingKeys: String, CodingKey {
            case playCount = "play_count"
            case commentCount = "comment_count"
        }
    }

    enum CodingKeys: String, CodingKey {
        case awemeID = "aweme_id"
        case desc, cover, video, author, statistics
    }

    func toVideoItem() -> VideoItem {
        let playURLStr = video.playAddr.urlList.first ?? ""
        // 抖音 awemeID 转 aid 用不到，bvid/cid 默认 0
        let aidInt = Int(awemeID) ?? 0
        return VideoItem(
            id: awemeID,
            aid: aidInt,
            bvid: "",
            cid: 0,
            title: desc,
            coverURL: cover.urlList.first ?? "",
            playURL: playURLStr,
            webURL: "",
            duration: video.duration / 1000,
            publishTime: .now,
            viewCount: statistics.playCount,
            danmakuCount: 0,
            commentCount: statistics.commentCount,
            authorUID: author.uid,
            authorName: author.nickname,
            authorAvatar: author.avatarThumb.urlList.first ?? "",
            platform: "douyin"
        )
    }
}

struct DouyinLiveRoomResponse: Codable, Sendable {
    let data: RoomData

    struct RoomData: Codable, Sendable {
        let room: RoomInfo

        struct RoomInfo: Codable, Sendable {
            let roomID: String
            let title: String
            let coverURL: CoverURL
            let userCountStr: String
            let owner: OwnerInfo
            let liveStatus: Int

            struct CoverURL: Codable, Sendable {
                let urlList: [String]
                enum CodingKeys: String, CodingKey { case urlList = "url_list" }
            }

            struct OwnerInfo: Codable, Sendable {
                let nickname: String
                let avatarThumb: CoverURL
                struct CoverURL: Codable, Sendable {
                    let urlList: [String]
                    enum CodingKeys: String, CodingKey { case urlList = "url_list" }
                }
                enum CodingKeys: String, CodingKey {
                    case nickname
                    case avatarThumb = "avatar_thumb"
                }
            }

            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case title
                case coverURL = "cover"
                case userCountStr = "user_count_str"
                case owner
                case liveStatus = "live_status"
            }
        }
    }

    func toLiveRoom() -> LiveRoom {
        let r = data.room
        return LiveRoom(
            id: r.roomID,
            roomID: r.roomID,
            title: r.title,
            coverURL: r.coverURL.urlList.first ?? "",
            streamURL: "",
            viewerCount: Int(r.userCountStr) ?? 0,
            authorUID: "",
            authorName: r.owner.nickname,
            authorAvatar: r.owner.avatarThumb.urlList.first ?? "",
            platform: "douyin",
            isLive: r.liveStatus == 1
        )
    }
}
