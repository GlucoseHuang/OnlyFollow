import Foundation

/// 简单文件日志，写入 Documents/OnlyFollow.log
enum AppLogger {
    private static let queue = DispatchQueue(label: "com.personal.OnlyFollow.logger")
    private static let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("OnlyFollow.log")
    }()

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "INFO", message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "ERROR", message, file: file, line: line)
    }

    static func warning(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "WARN", message, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "DEBUG", message, file: file, line: line)
    }

    private static func log(level: String, _ message: String, file: String, line: Int) {
        queue.sync {
            let filename = URL(fileURLWithPath: file).lastPathComponent
            let timestamp = DateFormatter.iso8601.string(from: Date())
            let line = "[\(timestamp)] [\(level)] [\(filename):\(line)] \(message)\n"

            // 也输出到 console
            print(line, terminator: "")

            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    /// 读取全部日志
    static func readLog() -> String {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return "(empty)" }
        return content
    }

    /// 日志文件路径（给用户看）
    static var logFilePath: String { logFileURL.path }
}

extension DateFormatter {
    static let iso8601: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
