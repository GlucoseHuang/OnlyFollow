import Foundation
import CryptoKit

/// 抖音直播 WebSocket signature 生成器
///
/// 算法（参考 saermart/DouyinLiveWebFetcher liveMan.py）：
/// 1. 拼 plaintext (逗号分隔,字段顺序固定):
///    `live_id=1,aid=6383,version_code=180800,webcast_sdk_version=1.0.14-beta.0,
///     room_id={room_id},sub_room_id=,sub_channel_id=,did_rule=3,
///     user_unique_id={user_unique_id},device_platform=web,
///     device_type=,ac=,identity=audience`
/// 2. MD5(plaintext) → 32 字符 hex 字符串
/// 3. `get_sign(md5Hex)` → 16 字符的 webcast signature (实际是 X-Bogus 算法对
///    `{"X-MS-STUB": md5Hex}` 算出来的值, 和 HTTP API 的 X-Bogus 同源同长度)
/// 4. `xMsStub` 就是 MD5 hex 本身
/// 5. **关键**: WS URL 里的参数必须和 plaintext 完全一致, 否则服务端重算 MD5 对不上
enum DouyinLiveSignature {

    /// 拼 plaintext (抖音直播 WS signature 算法的明文模板,字段顺序固定)
    /// - webcast_sdk_version 用 1.0.14 (与 wsURL 里的 version_code 180800 配套)
    /// - aid=6383 是抖音 web 端标准 aid
    static func plaintext(roomId: String, userUniqueId: String) -> String {
        return "live_id=1,aid=6383,version_code=180800,webcast_sdk_version=1.0.14-beta.0,room_id=\(roomId),sub_room_id=,sub_channel_id=,did_rule=3,user_unique_id=\(userUniqueId),device_platform=web,device_type=,ac=,identity=audience"
    }

    /// WS URL 模板 — 完全对齐 saermart/DouyinLiveWebFetcher liveMan.py 的格式
    /// - 关键: URL 参数必须和 plaintext 完全一致 (服务端会从 URL 提参重算 MD5 校验 signature)
    /// - webcast_sdk_version / update_version_code 用 1.0.14-beta.0 (与 plaintext 一致)
    /// - cursor 用 d-1_u-1_fh-..._t-..._r-1 格式
    /// - internal_ext 用 wrds_v 而非 wrds_kvs, 加 first_req_ms
    /// - 加 support_wrds=1 / insert_task_id= / live_reason= / room_id= 参数
    /// - browser_platform=Win32 (和桌面 Chrome UA 匹配)
    static func wsURL(roomId: String, userUniqueId: String, signature: String, xMsStub: String, cookie: String, userAgent: String) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let firstReqMs = now - 100
        let cursor = "d-1_u-1_fh-\(now)_t-\(now)_r-1"
        let internalExt = "internal_src:dim|wss_push_room_id:\(roomId)|wss_push_did:\(userUniqueId)|first_req_ms:\(firstReqMs)|fetch_time:\(now)|seq:1|wss_info:0-\(now)-0-0|wrds_v:\(now)"
        let uaOut = uaEncoded(userAgent)
        let extOut = uaEncoded(internalExt)
        let cursorOut = uaEncoded(cursor)

        let sigOut = sigEncoded(signature)
        let stubOut = sigEncoded(xMsStub)
        return """
        wss://webcast3-ws-web-hl.douyin.com/webcast/im/push/v2/?app_name=douyin_web&version_code=180800&webcast_sdk_version=1.0.14-beta.0&update_version_code=1.0.14-beta.0&compress=gzip&device_platform=web&cookie_enabled=true&screen_width=1536&screen_height=864&browser_language=zh-CN&browser_platform=Win32&browser_name=Mozilla&browser_version=\(uaOut)&browser_online=true&tz_name=Asia/Shanghai&cursor=\(cursorOut)&internal_ext=\(extOut)&host=https%3A%2F%2Flive.douyin.com&aid=6383&live_id=1&did_rule=3&endpoint=live_pc&support_wrds=1&user_unique_id=\(userUniqueId)&im_path=/webcast/im/fetch/&identity=audience&need_persist_msg_count=15&insert_task_id=&live_reason=&room_id=\(roomId)&heartbeatDuration=0&signature=\(sigOut)&X-MS-STUB=\(stubOut)
        """
    }

    /// 心跳 ack 帧
    static func heartbeatFrame() -> Data {
        var data = Data(count: 20)
        data[16] = 0x0b
        return data
    }

    /// 完整签名结果
    struct Result: Sendable {
        let signature: String
        let xMsStub: String
    }

    /// 主入口: 计算 signature
    /// - 走 `DouyinWebcastSigner` (独立 WKWebView + sign.js) 算真正的 webcast signature
    /// - 之前走 byted_acrawler / __get_ab 拿到的是 a-bogus (188 字符), 会被服务端 -1011 拒掉
    static func compute(roomId: String, userUniqueId: String, cookie: String, userAgent: String) async throws -> Result {
        let plaintext = Self.plaintext(roomId: roomId, userUniqueId: userUniqueId)
        let md5Hex = Self.md5Hex(plaintext)
        AppLogger.info("DouyinLiveSignature: plaintext=\(plaintext.prefix(120))...")
        AppLogger.info("DouyinLiveSignature: MD5 hex = \(md5Hex)")

        let signature = try await DouyinWebcastSigner.shared.sign(md5Hex: md5Hex)
        AppLogger.info("DouyinLiveSignature: signature len=\(signature.count)")
        return Result(signature: signature, xMsStub: md5Hex)
    }

    // MARK: - MD5 (use CryptoKit)
    private static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URL encode helper
    private static func uaEncoded(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=;[]")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 对 signature / xMsStub 用严格编码 (base64 含 +/= 等必须 percent-encode)
    private static func sigEncoded(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
