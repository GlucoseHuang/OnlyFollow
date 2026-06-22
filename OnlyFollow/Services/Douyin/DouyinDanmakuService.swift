import Foundation
import Compression

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
                    let ack = DouyinLiveSignature.heartbeatFrame()
                    self.task?.send(.data(ack)) { error in
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
    /// - PushFrame 头部: seqId(8) + logId(8) + service(8) + method(8) = 32 字节
    /// - 之后是 varint 编码的 headers 列表
    /// - 然后是 varint payloadEncoding
    /// - 然后是 varint payloadType
    /// - 然后是 varint payload 长度 + payload 字节
    /// (抖音实际是变长 varint,我们用简化的"32 字节头 + 直接找 payload 长度"做法)
    private func parseFrame(data: Data) {
        // 这里我们用 protobuf 二进制解码 (不是 varint 严格实现,而是直接读)
        // 简化做法: 跳过前 32 字节(4 个 uint64), 找 payload 字段
        // 抖音的真实帧格式：
        //   header (32 bytes) + varint(int) = payload 长度 + payload 字节
        // 但 varint 不是定长的，所以我们改成 "从后往前" 找 payload

        // 实际上抖音直播 WS 帧是"TLV-like" 自定义二进制协议，不是标准 protobuf wire format
        // 我们从已知样本中提取规律: payload 长度是帧的最后 4 字节
        // 但抖音有时变 (有时 8 字节),所以最稳妥的方式是：手动 varint 解码

        guard let frame = try? PushFrameDecoder.decode(data) else {
            AppLogger.error("DouyinDanmakuService: PushFrame 解码失败 (len=\(data.count))")
            return
        }

        let payloadData: Data
        if frame.payloadEncoding == "gzip" || (frame.payloadEncoding.isEmpty && frame.payloadType.isEmpty) {
            // 客户端→服务端的心跳 ack 也用 "gzip" encoding
            // 但 payload 通常很短(20字节左右) — 可能是心跳,跳过
            if frame.payload.count < 100 {
                return
            }
            payloadData = (try? frame.payload.gunzipped()) ?? Data()
        } else {
            payloadData = frame.payload
        }

        // 解 Response
        guard let response = try? ResponseDecoder.decode(payloadData) else {
            AppLogger.error("DouyinDanmakuService: Response 解码失败 (len=\(payloadData.count))")
            return
        }
        handleResponse(response)
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
        // payload 是 JSON 字符串 {"content": "<base64 文本>", "user": {"nickname": "..."}, ...}
        guard let payloadData = msg.payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let contentB64 = json["content"] as? String else {
            return
        }
        // 解 base64 拿到弹幕内容
        guard let decoded = Data(base64Encoded: contentB64),
              let text = String(data: decoded, encoding: .utf8) else {
            return
        }
        let userName = (json["user"] as? [String: Any])?["nickname"] as? String ?? ""
        let danmaku = DanmakuMessage(content: text, color: 0xFFFFFF, senderName: userName)
        messages.append(danmaku)
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
    }

    private func handleRoomStats(_ msg: MessageData) {
        // payload JSON: {"display_long": "1234", "display_short": "1.2万", ...}
        guard let payloadData = msg.payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let count = json["display_long"] as? Int else {
            return
        }
        viewerCount = count
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DouyinDanmakuService: URLSessionWebSocketDelegate {
    // didOpenWithProtocol / didCloseWith 已通过 method 实现 (因为 method 用了 @MainActor 隔离,delegate 是 nonisolated)
}

// MARK: - 简化的 PushFrame 解码器

/// 抖音 PushFrame 的简化解码器 — 我们只需要 method 和 payload 两个字段
struct PushFrameDecoder {
    static func decode(_ data: Data) throws -> (method: UInt64, payload: Data, payloadEncoding: String, payloadType: String) {
        // 实测抖音帧结构 (从 skmcj/dycast 提取):
        //   [0..8)   seqId       (uint64 LE)
        //   [8..16)  logId       (uint64 LE)
        //   [16..24) service      (uint64 LE)
        //   [24..32) method      (uint64 LE)
        //   [32..]   headers     (varint count + varint k1 + varint v1 + ... 都不定长)
        //   然后是 varint payloadEncoding (string)
        //   然后是 varint payloadType (string)
        //   然后是 varint payload 长度 + payload 字节
        //
        // 但更简单且实测有效的做法是：
        //   method 已知永远是 0x03 (SendMessage), 我们跳过
        //   直接找最后一块 [varint_len][bytes] 作为 payload

        var cursor = 32
        // skip headers: 第 32 字节开始是 varint 编码的 "headers 的数量",然后每个 header 是 2 个 varint
        guard cursor < data.count else { throw NSError(domain: "PushFrame", code: 1) }
        let headerCount = try readVarint(data: data, offset: &cursor)
        // 简化做法: 不解析 headers,直接扫到最后找 payload
        // 抖音的 payload 是"压轴"字段,前面是 headers(数量 + 多对 k/v varint)
        // 简化: 跳过 (headerCount * 2) 个 varint
        for _ in 0..<headerCount * 2 {
            _ = try readVarint(data: data, offset: &cursor)
        }
        // payloadEncoding (string): varint 长度 + bytes
        let encodingLen = try readVarint(data: data, offset: &cursor)
        let encodingBytes = data.subdata(in: cursor..<(cursor + Int(encodingLen)))
        cursor += Int(encodingLen)
        // payloadType (string): varint 长度 + bytes
        let typeLen = try readVarint(data: data, offset: &cursor)
        let typeBytes = data.subdata(in: cursor..<(cursor + Int(typeLen)))
        cursor += Int(typeLen)
        // payload: varint 长度 + bytes
        let payloadLen = try readVarint(data: data, offset: &cursor)
        guard cursor + Int(payloadLen) <= data.count else { throw NSError(domain: "PushFrame", code: 2) }
        let payload = data.subdata(in: cursor..<(cursor + Int(payloadLen)))

        return (
            method: 0,
            payload: payload,
            payloadEncoding: String(data: encodingBytes, encoding: .utf8) ?? "",
            payloadType: String(data: typeBytes, encoding: .utf8) ?? ""
        )
    }

    static func readVarint(data: Data, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 64 { throw NSError(domain: "varint", code: 1) }
        }
        throw NSError(domain: "varint", code: 2)
    }
}

// MARK: - 简化的 Response 解码器

struct ResponseData {
    let messages: [MessageData]
}

struct MessageData {
    let method: String
    let payload: String
}

struct ResponseDecoder {
    static func decode(_ data: Data) throws -> ResponseData {
        // Response 结构:
        //   field 1 (messages): tag = (1<<3)|2 = 0x0A, varint count + (tag=0x0A, varint len, bytes) * count
        //   field 4 (id):       tag = (4<<3)|0 = 0x20, varint
        //   field 5 (result):  tag = (5<<3)|0 = 0x28, varint
        //   field 6 (host):    tag = (6<<3)|2 = 0x32, varint len + bytes

        var cursor = 0
        var messages: [MessageData] = []

        while cursor < data.count {
            let tag = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch (fieldNumber, wireType) {
            case (1, 2):  // messages (length-delimited, packed repeated)
                let len = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                let endOfMessage = cursor + Int(len)
                let msg = try decodeMessage(data: data, start: cursor, end: endOfMessage)
                messages.append(msg)
                cursor = endOfMessage
            case (4, 0), (5, 0):  // id / result (varint)
                _ = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
            case (6, 2):  // host (length-delimited)
                let len = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                cursor += Int(len)
            default:
                // 未知字段,按 wire type 跳过
                switch wireType {
                case 0: _ = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                case 2:
                    let len = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                    cursor += Int(len)
                default:
                    throw NSError(domain: "Response", code: 1)
                }
            }
        }

        return ResponseData(messages: messages)
    }

    static func decodeMessage(data: Data, start: Int, end: Int) throws -> MessageData {
        var cursor = start
        var method = ""
        var payload = ""

        while cursor < end {
            let tag = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch (fieldNumber, wireType) {
            case (1, 2):  // method (string)
                let len = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                method = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            case (4, 2):  // payload (string)
                let len = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                payload = String(data: data.subdata(in: cursor..<(cursor + Int(len))), encoding: .utf8) ?? ""
                cursor += Int(len)
            case (2, 0), (3, 0):
                _ = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
            default:
                switch wireType {
                case 0: _ = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                case 2:
                    let len = try PushFrameDecoder.readVarint(data: data, offset: &cursor)
                    cursor += Int(len)
                default: break
                }
            }
        }

        return MessageData(method: method, payload: payload)
    }
}

// MARK: - gzip 解压

extension Data {
    func gunzipped() throws -> Data {
        let bufferSize = 4096
        var result = Data()
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!,
                                        src_size: 0,
                                        state: nil)
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { throw NSError(domain: "gzip", code: 1) }
        defer { compression_stream_destroy(&stream) }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var offset = 0
        while offset < count {
            let inputSize = Swift.min(count - offset, bufferSize)
            let processed = self.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int in
                guard let baseAddr = rawBuffer.baseAddress else { return 0 }
                let inputPtr = baseAddr.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                stream.src_ptr = inputPtr
                stream.src_size = inputSize
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                let rv = compression_stream_process(&stream, flags)
                if rv == COMPRESSION_STATUS_ERROR { return -1 }
                return inputSize
            }
            if processed < 0 { throw NSError(domain: "gzip", code: 2) }
            let written = bufferSize - Int(stream.dst_size)
            if written > 0 {
                result.append(buffer, count: written)
            }
            offset += processed
            if processed == 0 { break }
        }
        return result
    }
}
