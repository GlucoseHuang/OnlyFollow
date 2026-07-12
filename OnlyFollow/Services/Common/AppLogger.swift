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
        // 主线程卡顿修复: 之前 queue.sync 串行队列 + 每次 open/seek/write/close 文件
        //   bulk fetch 11 个 UP 主各打 1-2 条 INFO = 11-22 次 log
        //   每次 1-5ms(open file 主导), 22 次串行 = 22-110ms 主线程被锁
        //   更糟: queue.sync 会等前面任务完成, 排长队时主线程等几秒
        // 修法: 拆成两部分
        //   1) console print: 保持同步 (开发者调试需要)
        //   2) 文件 I/O: 丢到后台 serial queue (async, 不阻塞)
        //   日志顺序: serial queue 保证写入顺序; 进程崩溃时丢最新一两条可接受
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let timestamp = DateFormatter.iso8601.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(filename):\(line)] \(message)\n"

        // console 同步
        print(line, terminator: "")

        // 文件 I/O 异步
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [logFileURL] in
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
