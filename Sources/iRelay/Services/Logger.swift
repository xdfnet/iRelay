import Foundation
import Darwin
import AppKit

/// 文件日志，输出到 ~/.config/irelay/irelay.log
///
/// Output format:
///   [2026-06-04 23:37:02.616] [INFO] service_starting model=deepseek-v4-pro
///
/// Features:
///   - kebab-case event names (e.g. "service_starting", "codex_request")
///   - key-value pairs for structured context
///   - reopenable file writer (survives log rotation by external tools)
///   - stderr tee only when terminal is interactive
///   - async write on utility serial queue
enum Log {

    // MARK: - Paths

    private static let logDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("irelay")
    }()

    private static var logPath: URL {
        logDir.appendingPathComponent("irelay.log")
    }

    // MARK: - Formatting

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Dispatch

    private static let queue = DispatchQueue(label: "com.xdf.irelay.log", qos: .utility)

    // MARK: - reopenable writer state

    private static var _fileHandle: FileHandle?

    private static let isInteractive: Bool = {
        isatty(STDERR_FILENO) != 0
    }()

    // MARK: - Public API

    /// Log an INFO-level structured event.
    /// - Parameters:
    ///   - event: kebab-case event name (e.g. "service_starting", "codex_request")
    ///   - pairs: alternating key-value pairs for structured context
    static func info(_ event: String, _ pairs: Any...) {
        write(level: "INFO", event: event, pairs: pairs)
    }

    /// Log an ERROR-level structured event.
    static func error(_ event: String, _ pairs: Any...) {
        write(level: "ERROR", event: event, pairs: pairs)
    }

    /// Compute milliseconds elapsed since `start`.
    static func msSince(_ start: Date) -> Int64 {
        Int64(-start.timeIntervalSinceNow * 1000)
    }

    /// Open log file in default editor.
    static func open() {
        guard let url = URL(string: "file://\(logPath.path)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 提取输入的文本表示供日志展示。
    /// 只展开 user/assistant 消息，developer/system 和 tool 调用只显示摘要。
    static func summaryInput(_ input: Any?) -> String {
        guard let input else { return "" }
        if let s = input as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = input as? [Any] {
            if arr.isEmpty { return "(empty)" }
            let texts = arr.compactMap { item -> String? in
                guard let dict = item as? [String: Any] else { return nil }
                let type = dict["type"] as? String ?? ""
                let role = dict["role"] as? String ?? ""
                let label = type == "message" && !role.isEmpty ? role : type

                switch label {
                case "user", "assistant":
                    let text = contentText(dict["content"])
                    if text.isEmpty { return label }
                    return "\(label):\(text)"
                case "developer", "system":
                    let text = contentText(dict["content"])
                    let len = text.count
                    return "(system \(len) chars)"
                case "function_call":
                    let name = dict["name"] as? String ?? ""
                    return "(call \(name))"
                case "function_call_output":
                    return "(tool_result)"
                default:
                    return label
                }
            }
            return texts.joined(separator: " | ")
        }
        return "\(input)"
    }

    /// 从 content 字段中提取纯文本
    private static func contentText(_ content: Any?) -> String {
        guard let content else { return "" }
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
            let parts = arr.compactMap { item -> String? in
                if let dict = item as? [String: Any],
                   let text = dict["text"] as? String,
                   !text.isEmpty {
                    return text
                }
                return nil
            }
            return parts.joined(separator: " ")
        }
        return ""
    }

    /// Visual separator for request boundaries (matching iRelay's `END` line).
    static func end() {
        info("-------------------------END------------------------------")
    }

    // MARK: - Internal

    private static func write(level: String, event: String, pairs: [Any]) {
        queue.async {
            let time = dateFmt.string(from: Date())
            var line = "[\(time)] [\(level)] \(event)"

            var i = 0
            while i < pairs.count - 1 {
                if let key = pairs[i] as? String {
                    let raw = pairs[i + 1]
                    let val: String
                    if let err = raw as? Error {
                        val = err.localizedDescription
                    } else {
                        val = "\(raw)"
                    }
                    // 单行日志，转义换行和缩进
                    let safe = val
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "\\r")
                        .replacingOccurrences(of: "\t", with: "\\t")
                    line += " \(key)=\(safe)"
                }
                i += 2
            }

            line += "\n"

            // File write (reopenable — survives external rotation)
            reopenAndWrite(line)

            // stderr when running interactively
            if isInteractive, let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }

    /// reopenable write: check file existence, re-create if rotated away.
    private static func reopenAndWrite(_ line: String) {
        let path = logPath.path
        let fm = FileManager.default

        if !fm.fileExists(atPath: path) {
            _fileHandle?.closeFile()
            _fileHandle = nil
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }

        if _fileHandle == nil {
            _fileHandle = FileHandle(forWritingAtPath: path)
        }

        _fileHandle?.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            _fileHandle?.write(data)
        }
    }
}
