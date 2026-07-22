import Foundation
import os

/// 파일 + os.Logger 로 동시에 남기는 간단 로거. (fmt.Println 대신 구조적 로깅 원칙)
enum Log {
    private static let osLog = os.Logger(subsystem: "io.github.claudeaccountswitcher", category: "app")
    private static let iso = ISO8601DateFormatter()

    static func info(_ msg: String) { write("INFO", msg); osLog.info("\(msg, privacy: .public)") }
    static func error(_ msg: String) { write("ERROR", msg); osLog.error("\(msg, privacy: .public)") }

    private static func write(_ level: String, _ msg: String) {
        Paths.ensureAppDir()
        let line = "\(iso.string(from: Date())) [\(level)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Paths.logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Paths.logFile)
        }
    }
}
