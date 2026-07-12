import Foundation
import Compression
import zlib

/// 抖音直播弹幕服务（@MainActor ObservableObject）
///
/// 协议栈：
/// 1. WS 连接: `wss://webcast3-ws-web-hl.douyin.com/webcast/im/push/v2/...&signature=...&X-MS-STUB=...`
/// 2. 服务端 → 客户端：二进制帧 = PushFrame (proto bytes)
///    - payloadEncoding = "pb" 或 "gzip"
///    - payload = Response (proto bytes)
/// 3. Response.messages[] = Message
///    - Message.method = "WebcastChatMessage" → payload 是 JSON 字符串 {"content": "<base64>", "user": {...}}
///    - Message.method = "WebcastRoomStatsMessage" → payload 是 JSON 字符串 {"display_long": "1234"}
/// 4. 心跳：每 5s 发一次空 ack (proto bytes)
///
/// 签名生成：见 DouyinLiveSignature — MD5(明文) + RC4 + 魔改码表
///
/// 关键差异（vs B 站弹幕）：
/// - B 站是 JSON over WS + 16 字节头 + zlib
/// - 抖音是 proto bytes + gzip + 二进制 varint 编码字段长度
///
/// 注：本实现用手写二进制解码（不需要 SwiftProtobuf codegen），
///     因为抖音 proto 字段太多，全 codegen 出来二进制 2MB+ 不划算。
///     我们只解析 envelope (PushFrame + Response) 和我们关心的两个 Message。
@MainActor
final class DouyinDanmakuService: NSObject, ObservableObject {
    @Published var messages: [DanmakuMessage] = []
    @Published var viewerCount: Int = 0
    @Published var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var userUniqueId: String = ""   // 客户端 ID（用于 WS URL 中的 wss_push_did）
    private var signature: String = ""       // WS signature
    private var xMsStub: String = ""         // X-MS-STUB (与 signature 同值,旧版兼容)

    private let roomId: String
    private let ownerSecUid: String?

    init(roomId: String, ownerSecUid: String? = nil) {
        self.roomId = roomId
        self.ownerSecUid = ownerSecUid
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func connect() async {
        // 1. 准备 userUniqueId (设备指纹,优先 cookie 里的 odin_tt,否则生成)
        userUniqueId = await fetchOrGenerateUserUniqueId()

        // 2. 准备 signature
        do {
            let sig = try await DouyinLiveSignature.compute(
                roomId: roomId,
                userUniqueId: userUniqueId,
                cookie: await DouyinSessionManager.shared.cookieString,
                userAgent: DouyinSigner.desktopUA
            )
            signature = sig.signature
            xMsStub = sig.xMsStub
        } catch {
            AppLogger.error("DouyinDanmakuService: 签名失败: \(error.localizedDescription)")
            return
        }

        // 3. 拼 URL
        let urlString = DouyinLiveSignature.wsURL(
            roomId: roomId,
            userUniqueId: userUniqueId,
            signature: signature,
            xMsStub: xMsStub,
            cookie: await DouyinSessionManager.shared.cookieString,
            userAgent: DouyinSigner.desktopUA
        )
        guard let url = URL(string: urlString) else {
            AppLogger.error("DouyinDanmakuService: 无效 WS URL")
            return
        }
        AppLogger.info("DouyinDanmakuService: connecting \(url.host ?? "?")... (room=\(roomId))")

        // 4. 建连
        var request = URLRequest(url: url)
        request.setValue(DouyinSigner.desktopUA, forHTTPHeaderField: "User-Agent")
        let cookie = await DouyinSessionManager.shared.cookieString
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let t = session.webSocketTask(with: request)
        self.task = t
        t.resume()
        // 等 didOpenWithProtocol 回调再 isConnected = true
    }

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        AppLogger.info("DouyinDanmakuService: disconnected")
    }

    // MARK: - User unique id

    private func fetchOrGenerateUserUniqueId() async -> String {
        // 优先用 cookie 里的 odin_tt,否则生成
        let cookie = await DouyinSessionManager.shared.cookieString
        for kv in cookie.split(separator: ";") {
            let parts = kv.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "odin_tt" {
                return String(parts[1])
            }
        }
        // 生成一个 19 位数字（与抖音客户端 ID 形态一致）
        return String(Int(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: - Receive

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.isConnected = true
            self.reconnectAttempts = 0
            AppLogger.info("DouyinDanmakuService: WS opened")
            self.startReceiving()
            self.startHeartbeat()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            self.isConnected = false
            AppLogger.info("DouyinDanmakuService: WS closed code=\(closeCode.rawValue)")
            self.scheduleReconnect()
        }
    }

    private func startReceiving() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.parseFrame(data: data)
                    case .string(let text):
                        AppLogger.info("DouyinDanmakuService: text frame: \(text.prefix(100))")
                    @unknown default:
                        break
                    }
                    // 继续读下一帧
                    self.startReceiving()
                case .failure(let error):
                    AppLogger.error("DouyinDanmakuService: receive error: \(error.localizedDescription)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
                if Task.isCancelled { break }
                if self.isConnected {
                    // 标准心跳: PushFrame(payload_type='hb') protobuf 编码
                    let hb = PushFrameEncoder.heartbeat()
                    self.task?.send(.data(hb)) { error in
                        if let error {
                            AppLogger.error("DouyinDanmakuService: heartbeat send failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let delay = min(30, pow(2.0, Double(reconnectAttempts)))  // 2,4,8,16,30s
        AppLogger.info("DouyinDanmakuService: 将在 \(Int(delay))s 后重连 (第 \(reconnectAttempts) 次)")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.connect()
        }
    }

    // MARK: - Parse frame

    /// 解析一个 PushFrame 帧
    /// - PushFrame 是标准 protobuf message (非固定头), 字段可乱序可省略
    /// - proto3 默认值(0/空)不编码, 所以极小心跳帧只有 payloadType="hb" 一个字段
    /// - 服务端 push 帧: 必有 payload(field 8) + 可能的 payloadEncoding(field 6, "gzip"|"pb")
    /// - payload 是 gzip 压缩的 Response (proto bytes)
    private func parseFrame(data: Data) {
        AppLogger.info("DouyinDanmakuService: 收到 WS 帧 raw len=\(data.count) hex0:8=\(data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
        guard let frame = try? PushFrameDecoder.decode(data) else {
            AppLogger.error("DouyinDanmakuService: PushFrame 解码失败 (len=\(data.count))")
            sendAckForAnyFrame(data: data)
            return
        }
        // 记住 logId, 服务端可能要求原样回 ack (saermart 实测)
        lastLogId = frame.logId
        AppLogger.info("DouyinDanmakuService: PushFrame 解码 ok — logId=\(frame.logId) payloadType=\(frame.payloadType) payloadEncoding=\(frame.payloadEncoding) payloadLen=\(frame.payload.count)")

        // 服务端→客户端的心跳 ack 帧只有 payloadType="hb" 没有真正的弹幕 payload
        // 跳过短 payload (心跳 ack payload 一般 20 字节左右)
        if frame.payloadType == "hb" || frame.payload.isEmpty {
            return
        }

        let payloadData: Data
        // 抖音服务端撒谎: payloadEncoding 字段常为 "pb" 但实际 payload 是 gzip 压缩
        // 必须看头两个字节 (gzip magic = 0x1f 0x8b) 决定是否解压
        if frame.payloadEncoding == "gzip" || frame.payload.starts(with: [0x1f, 0x8b]) {
            do {
                payloadData = try frame.payload.gunzipped()
                AppLogger.info("DouyinDanmakuService: gunzipped \(frame.payload.count) -> \(payloadData.count) bytes (encoding=\(frame.payloadEncoding))")
            } catch {
                AppLogger.error("DouyinDanmakuService: gunzip 失败: \(error.localizedDescription) — 原始 payload hex0:8=\(frame.payload.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
                return
            }
        } else {
            payloadData = frame.payload
            AppLogger.info("DouyinDanmakuService: raw pb payload \(payloadData.count) bytes (encoding=\(frame.payloadEncoding))")
        }

        guard let response = try? ResponseDecoder.decode(payloadData) else {
            AppLogger.error("DouyinDanmakuService: Response 解码失败 (len=\(payloadData.count), encoding=\(frame.payloadEncoding), hex0:8=\(payloadData.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
            return
        }
        AppLogger.info("DouyinDanmakuService: Response 解析成功 — \(response.messages.count) msgs, methods=\(response.messages.map { $0.method }.joined(separator: ","))")
        // need_ack 时回 ack (saermart 标准: 服务端发完一批消息要 ack)
        if response.needAck {
            sendAck(internalExt: response.internalExt)
        }
        handleResponse(response)
    }

    /// 记住最后收到的 logId (用于 ack)
    private var lastLogId: UInt64 = 0

    /// 通用兜底 ack: 没成功解 PushFrame 时也回个空 ack, 不至于被服务端踢
    private func sendAckForAnyFrame(data: Data) {
        // 解不出 logId 就用 0 当兜底, 服务端会忽略
        sendAck(internalExt: "")
    }

    /// 发送 ack 帧 (PushFrame(payload_type='ack', payload=internalExt))
    private func sendAck(internalExt: String) {
        let ack = PushFrameEncoder.ack(logId: lastLogId, internalExt: internalExt)
        task?.send(.data(ack)) { error in
            if let error {
                AppLogger.error("DouyinDanmakuService: ack send failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleResponse(_ resp: ResponseData) {
        for msg in resp.messages {
            switch msg.method {
            case "WebcastChatMessage":
                handleChatMessage(msg)
            case "WebcastRoomStatsMessage":
                handleRoomStats(msg)
            case "WebcastMemberMessage":
                // 进场消息 — 暂时不渲染
                break
            default:
                // 其他类型: 礼物、点赞、关注等 — 暂时忽略
                break
            }
        }
    }

    private func handleChatMessage(_ msg: MessageData) {
        // ChatMessage proto (saermart/douyin.proto):
        //   Common common = 1
        //   User user = 2 (其中 nickName = field 3)
        //   string content = 3
        guard let payloadData = msg.rawPayload, payloadData.count > 0 else {
            AppLogger.warning("DouyinDanmakuService: ChatMessage.rawPayload 为空")
            return
        }
        do {
            let chat = try ChatMessageDecoder.decode(payloadData)
            AppLogger.info("DouyinDanmakuService: ChatMessage 解析成功 — nick=\(chat.nickName) content=\(chat.content)")
            let danmaku = DanmakuMessage(content: chat.content, color: 0xFFFFFF, senderName: chat.nickName)
            messages.append(danmaku)
            if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        } catch {
            AppLogger.error("DouyinDanmakuService: ChatMessage 解析失败 — rawPayload len=\(payloadData.count) hex0:32=\(payloadData.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
    }

    private func handleRoomStats(_ msg: MessageData) {
        // RoomStatsMessage proto:
        //   displayShort = 2 (如 "1.2万")
        //   displayLong  = 4 (如 "1234" 或 "1234在线观众" 或 "1.2万在线观众")
        guard let payloadData = msg.rawPayload, payloadData.count > 0 else { return }
        guard let stats = try? RoomStatsMessageDecoder.decode(payloadData) else { return }
        if let n = Self.parseViewerCount(from: stats.displayLong) {
            if n != viewerCount {
                AppLogger.info("DouyinDanmakuService: 直播间人数 update displayLong=\(stats.displayLong) → \(n)")
            }
            viewerCount = n
        } else {
            AppLogger.warning("DouyinDanmakuService: 解析 displayLong 失败: \(stats.displayLong)")
        }
    }

    /// 从抖音 displayLong (如 "1234在线观众" / "1.2万在线观众" / "12万" / "0") 提取实际人数
    /// - 万 = ×10_000
    /// - 千 = ×1_000
    /// - 亿 = ×100_000_000
    private static func parseViewerCount(from s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // 提取前导数字 (整数或小数, 仅 ASCII 0-9 + ASCII 小数点)
        var numStr = ""
        var seenDot = false
        for ch in trimmed {
            if ch.isASCII && ch.isNumber {
                numStr.append(ch)
            } else if ch == "." && !seenDot {
                numStr.append(".")
                seenDot = true
            } else {
                break
            }
        }
        guard let base = Double(numStr), base >= 0 else { return nil }
        // 找第一个中文字符判断单位
        var multiplier: Double = 1
        for ch in trimmed {
            switch ch {
            case "万": multiplier = 10_000; break
            case "千": multiplier = 1_000; break
            case "亿": multiplier = 100_000_000; break
            default: continue
            }
            if multiplier != 1 { break }
        }
        let result = base * multiplier
        return Int(result.rounded())
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DouyinDanmakuService: URLSessionWebSocketDelegate {
    // didOpenWithProtocol / didCloseWith 已通过 method 实现 (因为 method 用了 @MainActor 隔离,delegate 是 nonisolated)
}

// MARK: - 通用 protobuf wire format 工具

enum ProtoWire {
    /// 读 varint (LEB128)
    static func readVarint(data: Data, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 70 { throw NSError(domain: "varint", code: 1) }
        }
        throw NSError(domain: "varint", code: 2)
    }

    /// 写 varint (LEB128)
    static func writeVarint(_ value: UInt64) -> Data {
        var result = Data()
        var v = value
        while v >= 0x80 {
            result.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }

    /// 按 wire type 跳过未知字段 (0=varint, 1=fixed64, 2=len-delimited, 5=fixed32)
    static func skipField(data: Data, offset: inout Int, wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint(data: data, offset: &offset)
        case 1: offset += 8           // fixed64
        case 2:
            let len = try readVarint(data: data, offset: &offset)
            offset += Int(len)
        case 5: offset += 4           // fixed32
        default: throw NSError(domain: "proto", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown wire type \(wireType)"])
        }
    }
}

// MARK: - PushFrame 解码器 (标准 proto wire format)

/// PushFrame proto (来自 douyin_live.proto):
///   uint64 seqId = 1;
///   uint64 logId = 2;
///   uint64 service = 3;
///   uint64 method = 4;
///   repeated Header headers = 5;
///   string payloadEncoding = 6;
///   string payloadType = 7;
///   bytes payload = 8;
struct PushFrameData {
    let logId: UInt64           // 服务端 push 时给的 id, ack 要原样回
    let payloadEncoding: String
    let payloadType: String
    let payload: Data
}

struct PushFrameDecoder {
    static func decode(_ data: Data) throws -> PushFrameData {
        var logId: UInt64 = 0
        var payloadEncoding = ""
        var payloadType = ""
        var payload = Data()

        var cursor = 0
        while cursor < data.count {
            let tag = try ProtoWire.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            switch fieldNumber {
            case 2 where wireType == 0:  // logId
                logId = try ProtoWire.readVarint(data: data, offset: &cursor)
            case 6 where wireType == 2:  // payloadEncoding (string)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                payloadEncoding = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            case 7 where wireType == 2:  // payloadType (string)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                payloadType = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            case 8 where wireType == 2:  // payload (bytes)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                payload = data.subdata(in: cursor..<(cursor + Int(len)))
                cursor += Int(len)
            default:
                try ProtoWire.skipField(data: data, offset: &cursor, wireType: wireType)
            }
        }
        return PushFrameData(logId: logId, payloadEncoding: payloadEncoding, payloadType: payloadType, payload: payload)
    }
}

// MARK: - PushFrame 编码器 (心跳 + ack)

enum PushFrameEncoder {
    /// 心跳: 只写 payloadType="hb", 其余字段全默认值(proto3 不编码)
    static func heartbeat() -> Data {
        var d = Data()
        d.append(0x3a)  // tag = (7<<3)|2 = 0x3a (payloadType, length-delimited)
        d.append(0x02)
        d.append(0x68); d.append(0x62)  // "hb"
        return d
    }

    /// ack: logId + payloadType="ack" + payload=internalExt (saermart 的标准做法)
    static func ack(logId: UInt64, internalExt: String) -> Data {
        var d = Data()
        if logId != 0 {
            d.append(0x10)  // tag = (2<<3)|0 (logId varint)
            d.append(ProtoWire.writeVarint(logId))
        }
        d.append(0x3a)  // payloadType
        d.append(0x03)
        d.append(0x61); d.append(0x63); d.append(0x6b)  // "ack"
        let payloadBytes = Data(internalExt.utf8)
        d.append(0x42)  // tag = (8<<3)|2 (payload bytes)
        d.append(ProtoWire.writeVarint(UInt64(payloadBytes.count)))
        d.append(payloadBytes)
        return d
    }
}

// MARK: - Response 解码器 (标准 proto wire format)
//
// Response proto:
//   repeated Message messages = 1;
//   string internalExt         = 3;   (saermart 用作 ack 回执, 实际暂未在 proto 文件列出)
//   uint64 id                  = 4;
//   uint64 result              = 5;
//   string host                = 6;
//   bool needAck               = (具体字段号未知, saermart 用 response.need_ack)

struct ResponseData {
    let messages: [MessageData]
    let needAck: Bool
    let internalExt: String
}

struct MessageData {
    let method: String
    let rawPayload: Data?   // bytes, 该消息类型的 proto (如 ChatMessage)
}

struct ResponseDecoder {
    static func decode(_ data: Data) throws -> ResponseData {
        var cursor = 0
        var messages: [MessageData] = []
        var internalExt = ""
        var needAck = false

        while cursor < data.count {
            let tag = try ProtoWire.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            if fieldNumber == 1 && wireType == 2 {           // messages (repeated Message)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                let end = cursor + Int(len)
                let msg = try decodeMessage(data: data, start: cursor, end: end)
                messages.append(msg)
                cursor = end
            } else if fieldNumber == 5 && wireType == 2 {    // internalExt (string, saermart/douyin.proto:field5)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                internalExt = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            } else if fieldNumber == 9 && wireType == 0 {    // needAck (bool, field9)
                let v = try ProtoWire.readVarint(data: data, offset: &cursor)
                needAck = (v != 0)
            } else {
                try ProtoWire.skipField(data: data, offset: &cursor, wireType: wireType)
            }
        }
        return ResponseData(messages: messages, needAck: needAck, internalExt: internalExt)
    }

    static func decodeMessage(data: Data, start: Int, end: Int) throws -> MessageData {
        var cursor = start
        var method = ""
        var rawPayload: Data? = nil

        while cursor < end {
            let tag = try ProtoWire.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            if fieldNumber == 1 && wireType == 2 {            // method (string)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                method = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            } else if fieldNumber == 2 && wireType == 2 {     // payload (bytes, proto) — 不是 JSON!
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                rawPayload = data.subdata(in: cursor..<(cursor + Int(len)))
                cursor += Int(len)
            } else {
                try ProtoWire.skipField(data: data, offset: &cursor, wireType: wireType)
            }
        }
        return MessageData(method: method, rawPayload: rawPayload)
    }
}

// MARK: - ChatMessage proto decoder
//
// message ChatMessage {
//   Common common = 1;
//   User user = 2;       中 nickName = field 3 (string)
//   string content = 3;
// }
struct ChatMessageData {
    let nickName: String
    let content: String
}

enum ChatMessageDecoder {
    static func decode(_ data: Data) throws -> ChatMessageData {
        var cursor = 0
        var nickName = ""
        var content = ""

        while cursor < data.count {
            let tag = try ProtoWire.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            if fieldNumber == 2 && wireType == 2 {   // User (nested)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                nickName = try decodeUserNickName(data: data, start: cursor, length: Int(len))
                cursor += Int(len)
            } else if fieldNumber == 3 && wireType == 2 {  // content (string)
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                content = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            } else {
                try ProtoWire.skipField(data: data, offset: &cursor, wireType: wireType)
            }
        }
        return ChatMessageData(nickName: nickName, content: content)
    }

    private static func decodeUserNickName(data: Data, start: Int, length: Int) throws -> String {
        // message User { ... string nickName = 3; ... }
        let end = start + length
        var cursor = start
        var nick = ""
        while cursor < end {
            let tag = try ProtoWire.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            if fieldNumber == 3 && wireType == 2 {
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                nick = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
                break
            } else {
                try ProtoWire.skipField(data: data, offset: &cursor, wireType: wireType)
            }
        }
        return nick
    }
}

// MARK: - RoomStatsMessage proto decoder
//
// message RoomStatsMessage {
//   Common common = 1;
//   string displayShort = 2;
//   string displayMiddle = 3;
//   string displayLong = 4;
//   int64 displayValue = 5;
//   int64 total = 9;
// }
enum RoomStatsMessageDecoder {
    static func decode(_ data: Data) throws -> (displayLong: String, displayShort: String, total: Int64) {
        var cursor = 0
        var displayLong = ""
        var displayShort = ""
        var total: Int64 = 0
        while cursor < data.count {
            let tag = try ProtoWire.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            if fieldNumber == 2 && wireType == 2 {
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                displayShort = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            } else if fieldNumber == 4 && wireType == 2 {
                let len = try ProtoWire.readVarint(data: data, offset: &cursor)
                displayLong = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            } else if fieldNumber == 9 && wireType == 0 {
                let v = try ProtoWire.readVarint(data: data, offset: &cursor)
                total = Int64(bitPattern: v)
            } else {
                try ProtoWire.skipField(data: data, offset: &cursor, wireType: wireType)
            }
        }
        return (displayLong, displayShort, total)
    }
}

// MARK: - gzip 解压 (RFC 1952) — 走 Apple Compression 框架 (raw deflate → 加 zlib 头)

extension Data {
    /// 解压 gzip (1f 8b 头). 手动剥掉 gzip 头/尾, 用 libz 直接解 raw deflate (windowBits=-15).
    /// - 抖音 payload 是 gzip (RFC 1952), 剥掉头/尾后是 raw deflate (RFC 1951)
    /// - Apple `COMPRESSION_ZLIB` 框架**不能**解 raw deflate (会失败或产生乱码)
    /// - 必须用 libz 的 `inflate` 配合 windowBits=-15
    func gunzipped() throws -> Data {
        guard count >= 18 else { throw NSError(domain: "gzip", code: 1, userInfo: [NSLocalizedDescriptionKey: "too short"]) }
        guard self[0] == 0x1f, self[1] == 0x8b else { throw NSError(domain: "gzip", code: 2, userInfo: [NSLocalizedDescriptionKey: "not gzip magic"]) }

        // 解析 gzip header (RFC 1952):
        //   magic(2) + CM(1) + FLG(1) + MTIME(4) + XFL(1) + OS(1) = 10 字节 (基本头)
        var p = 2
        let cm = self[p]; p += 1
        guard cm == 8 else { throw NSError(domain: "gzip", code: 3, userInfo: [NSLocalizedDescriptionKey: "bad cm=\(cm)"]) }
        let flg = self[p]; p += 1
        p += 4                              // mtime
        p += 1                              // xfl
        p += 1                              // os  ← 这一行之前漏了! 导致 deflateStart 错位 1 字节
        if flg & 0x04 != 0 {                // FNAME
            while p < count, self[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x10 != 0 {                // FCOMMENT
            while p < count, self[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 }       // FHCRC
        guard p < count - 8 else { throw NSError(domain: "gzip", code: 4) }
        let deflateStart = p
        let deflateLen = count - 8 - p
        let deflateData = self.subdata(in: deflateStart..<(deflateStart + deflateLen))

        // 走 libz 直接调 inflate
        return try gunzippedLibZ(deflateData: deflateData)
    }

    /// libz 路径: 用 dlsym 加载 libz, 调 inflateInit2_ + inflate + inflateEnd
    /// 失败时回退到 zlib Swift module (旧路径, 保留作 backup)
    private func gunzippedLibZ(deflateData: Data) throws -> Data {
        // 加载 libz
        guard let handle = dlopen("/usr/lib/libz.dylib", RTLD_NOW) else {
            throw NSError(domain: "gzip", code: 10, userInfo: [NSLocalizedDescriptionKey: "dlopen libz failed"])
        }
        typealias InitFn = @convention(c) (UnsafeMutablePointer<z_stream>?, Int32, UnsafePointer<CChar>?, Int32) -> Int32
        typealias InflateFn = @convention(c) (UnsafeMutablePointer<z_stream>?, Int32) -> Int32
        typealias EndFn = @convention(c) (UnsafeMutablePointer<z_stream>?) -> Int32
        guard let initPtr = dlsym(handle, "inflateInit2_"),
              let infPtr = dlsym(handle, "inflate"),
              let endPtr = dlsym(handle, "inflateEnd") else {
            throw NSError(domain: "gzip", code: 11, userInfo: [NSLocalizedDescriptionKey: "dlsym libz funcs failed"])
        }
        let inflateInit2Fn = unsafeBitCast(initPtr, to: InitFn.self)
        let inflateFn = unsafeBitCast(infPtr, to: InflateFn.self)
        let inflateEndFn = unsafeBitCast(endPtr, to: EndFn.self)

        // 初始化 stream (-15 = raw deflate)
        var stream = z_stream(
            next_in: nil, avail_in: 0, total_in: 0,
            next_out: nil, avail_out: 0, total_out: 0,
            msg: nil, state: nil,
            zalloc: nil, zfree: nil, opaque: nil,
            data_type: 0, adler: 0, reserved: 0
        )
        let initRet: Int32 = ZLIB_VERSION.withCString { verPtr in
            inflateInit2Fn(&stream, -15, verPtr, Int32(MemoryLayout<z_stream>.size))
        }
        guard initRet == 0 else {
            throw NSError(domain: "gzip", code: 12, userInfo: [NSLocalizedDescriptionKey: "inflateInit2 failed: \(initRet)"])
        }
        defer { inflateEndFn(&stream) }

        // 分配输出 buffer (12x 输入, 一般 deflate ratio 2-5x)
        let outSize = Swift.max(64 * 1024, deflateData.count * 12)
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { outBuf.deallocate() }
        var result = Data()
        var totalDecoded = 0

        deflateData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let inBase = rawPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: inBase)
            stream.avail_in = uInt(deflateData.count)

            var currentOutBuf = outBuf
            var remaining = outSize

            while true {
                stream.next_out = currentOutBuf
                stream.avail_out = uInt(remaining)
                let ret = inflateFn(&stream, 0)  // Z_NO_FLUSH

                let written = remaining - Int(stream.avail_out)
                if written > 0 {
                    result.append(currentOutBuf, count: written)
                    totalDecoded += written
                    currentOutBuf = currentOutBuf.advanced(by: written)
                    remaining -= written
                }

                if ret == 1 { break }  // Z_STREAM_END
                if ret != 0 && ret != -5 {  // Z_OK = 0, Z_BUF_ERROR = -5 (OK 继续)
                    let msg = stream.msg.map { String(cString: $0) } ?? "?"
                    NSLog("gunzip: inflate failed ret=\(ret) msg=\(msg)")
                    return  // skip the rest
                }
                if stream.avail_in == 0 { break }  // input exhausted
                if stream.avail_out == 0 {
                    NSLog("gunzip: out buffer too small decoded=\(totalDecoded)")
                    return
                }
            }
        }
        return result
    }
}
