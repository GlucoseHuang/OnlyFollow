import Foundation
import Compression
import Starscream

@MainActor
final class BilibiliDanmakuService: NSObject, ObservableObject {
    @Published var messages: [DanmakuMessage] = []
    @Published var popularity: Int = 0
    @Published var isConnected = false

    private var socket: WebSocket?
    private var heartbeatTask: Task<Void, Never>?
    private let roomID: Int
    private let token: String
    private let host: String
    /// WSS 端口；B 站 2026 流程用 wss_port（通常是 2245），不是默认 443
    private let wssPort: Int
    /// B 站 buvid3，鉴权包带上能显著降低被风控踢掉的概率
    private let buvid: String

    init(roomID: Int, token: String, host: String, wssPort: Int = 443, buvid: String = "") {
        self.roomID = roomID
        self.token = token
        self.host = host
        self.wssPort = wssPort
        self.buvid = buvid
        super.init()
    }

    func connect() {
        // B 站 2026 推荐用 wss_port（2245）连新服，旧 fallback 才用默认 443
        let urlString = "wss://\(host):\(wssPort)/sub"
        guard let url = URL(string: urlString) else {
            AppLogger.error("BilibiliDanmaku: 无法构造 WebSocket URL \(urlString)")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        // Origin 必须用 live.bilibili.com，否则 B 站会拒
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        AppLogger.info("BilibiliDanmaku: 连接 \(urlString) roomID=\(roomID)")
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.disconnect()
        isConnected = false
    }

    // MARK: - Frame Protocol

    private func sendAuth() {
        // 2026 推荐鉴权 JSON：protover 3 (brotli) + buvid + queue_uuid + support_ack
        // 服务器会按 protover 3 返回 op=5，brotli 解压后是嵌套 zlib 帧，brotli 不支持时降级
        let queueUUID = String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: "").lowercased()
        let authBody: [String: Any] = [
            "uid": 0,
            "roomid": roomID,
            "protover": 3,
            "buvid": buvid,
            "support_ack": true,
            "queue_uuid": queueUUID,
            "scene": "",
            "platform": "web",
            "type": 2,
            "key": token
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: authBody) else { return }
        // 鉴权包必须用 protover=1（普通 JSON 正文），不要用 3
        let packet = buildPacket(operation: 7, body: json, protover: 1)
        socket?.write(data: packet)
    }

    private func sendHeartbeat() {
        let packet = buildPacket(operation: 2, body: Data("[object Object]".utf8))
        socket?.write(data: packet)
    }

    private func buildPacket(operation: Int, body: Data, protover: UInt16 = 2) -> Data {
        let headerLen = 16
        let totalLen = headerLen + body.count
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(totalLen).bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt16(headerLen).bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: protover.bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(operation).bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) })
        packet.append(body)
        return packet
    }

    private func parsePacket(_ data: Data) {
        guard data.count >= 16 else { return }

        let totalLen = data[0..<4].withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
        let headerLen = data[4..<6].withUnsafeBytes { Int($0.load(as: UInt16.self).bigEndian) }
        let protoVer = data[6..<8].withUnsafeBytes { Int($0.load(as: UInt16.self).bigEndian) }
        let operation = data[8..<12].withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }

        let payload = data[headerLen..<totalLen]

        switch operation {
        case 3:
            break
        case 5:
            handleCommand(payload: payload, protoVer: protoVer)
        case 8:
            if payload.count >= 4 {
                popularity = payload[0..<4].withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            }
        default:
            break
        }

        if totalLen < data.count {
            parsePacket(data[totalLen..<data.count])
        }
    }

    private func handleCommand(payload: Data, protoVer: Int) {
        let json: Data
        switch protoVer {
        case 0:
            json = payload
        case 2:
            guard let decompressed = try? payload.gunzipped() else { return }
            json = decompressed
        case 3:
            // protover 3 走 brotli；iOS Compression framework 用 COMPRESSION_BROTLI 解开
            // 解开后会得到一串嵌套的"普通包"，头部也是 16 字节，protover=0，body 是 JSON
            // 这里只解 brotli 外层，嵌套交给外层 parsePacket 递归处理
            guard let decompressed = try? payload.brotliDecoded() else {
                AppLogger.error("BilibiliDanmaku: brotli 解压失败，protover=3 但服务器不再降级到 zlib")
                return
            }
            // 嵌套帧：递归处理
            if decompressed.count >= 16 {
                parsePacket(decompressed)
            }
            return
        default:
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let cmd = obj["cmd"] as? String else { return }

        switch cmd {
        case "DANMU_MSG":
            guard let info = obj["info"] as? [[Any]],
                  info.count >= 2 else { return }
            let content = info[1] as? String ?? ""
            var color: UInt32 = 0xFFFFFF
            if info.count >= 3, let info2 = info[2] as? [Any], info2.count >= 4 {
                color = info2[3] as? UInt32 ?? 0xFFFFFF
            }
            var sender = ""
            if info.count >= 2, let info1 = info[0] as? [Any], info1.count >= 9 {
                sender = info1[9] as? String ?? ""
            }
            let msg = DanmakuMessage(content: content, color: color, senderName: sender)
            messages.append(msg)
            if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        default:
            break
        }
    }
}

// MARK: - WebSocketDelegate

extension BilibiliDanmakuService: WebSocketDelegate {
    func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected:
            isConnected = true
            sendAuth()
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    self?.sendHeartbeat()
                }
            }
        case .disconnected:
            isConnected = false
            heartbeatTask?.cancel()
        case .text:
            break
        case .binary(let data):
            parsePacket(data)
        case .error:
            isConnected = false
        default:
            break
        }
    }
}

// MARK: - Brotli via Compression framework (iOS 15+)

private extension Data {
    func brotliDecoded() throws -> Data {
        // B 站 op=5 + protover=3 用 brotli 压缩；解压后是嵌套的"普通包"
        // 嵌套包头部 16 字节，protover=0，body 才是 JSON
        let bufferSize = 4096
        var result = Data()
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!,
                                        src_size: 0,
                                        state: nil)
        // 实际使用：调 compression_stream_init + 循环 decode
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw NSError(domain: "brotli", code: -1)
        }
        defer { compression_stream_destroy(&stream) }

        let dstCapacity = bufferSize
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        return try self.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) in
            stream.src_ptr = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = count
            stream.dst_ptr = dstBuffer
            stream.dst_size = dstCapacity

            while true {
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_END {
                    let produced = dstCapacity - Int(stream.dst_size)
                    if produced > 0 {
                        result.append(dstBuffer, count: produced)
                    }
                    break
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw NSError(domain: "brotli", code: -2)
                }
                // 输出已满 / 需要更多输入：先把已产出的数据取走，然后看是源耗尽还是 dst 满
                let produced = dstCapacity - Int(stream.dst_size)
                if produced > 0 {
                    result.append(dstBuffer, count: produced)
                    stream.dst_ptr = dstBuffer
                    stream.dst_size = dstCapacity
                }
                if stream.src_size == 0 {
                    break
                }
            }
            return result
        }
    }
}
