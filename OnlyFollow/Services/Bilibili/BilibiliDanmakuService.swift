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

    init(roomID: Int, token: String, host: String) {
        self.roomID = roomID
        self.token = token
        self.host = host
        super.init()
    }

    func connect() {
        let url = URL(string: "wss://\(host)/sub")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
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
        let authBody: [String: Any] = [
            "uid": 0,
            "roomid": roomID,
            "protover": 2,
            "platform": "web",
            "type": 2,
            "key": token
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: authBody) else { return }
        let packet = buildPacket(operation: 7, body: json)
        socket?.write(data: packet)
    }

    private func sendHeartbeat() {
        let packet = buildPacket(operation: 2, body: Data("[object Object]".utf8))
        socket?.write(data: packet)
    }

    private func buildPacket(operation: Int, body: Data) -> Data {
        let headerLen = 16
        let totalLen = headerLen + body.count
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(totalLen).bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt16(headerLen).bigEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt16(2).bigEndian) { Array($0) })
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

// MARK: - Gzip via Compression framework

private extension Data {
    func gunzipped() throws -> Data {
        // Apple Compression framework: DEFLATE decompression
        // filter = COMPRESSION_ZLIB_DECODE handles zlib/gzip
        let bufferSize = 4096
        var result = Data()
        var offset = 0

        while offset < count {
            let input = self[offset...]
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let processed = try input.withUnsafeBytes { inputPtr in
                try buffer.withUnsafeMutableBytes { bufferPtr in
                    let written = compression_decode_buffer(
                        bufferPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        bufferSize,
                        inputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                    if written == 0 && input.count > 0 {
                        throw NSError(domain: "gzip", code: -1)
                    }
                    return written
                }
            }
            result.append(Data(buffer.prefix(processed)))
            offset += Swift.min(input.count, bufferSize)
            if processed == 0 { break }
        }

        return result
    }
}
