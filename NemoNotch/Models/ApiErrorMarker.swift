import Foundation

/// Recognizes Claude Code's terminal API failures in a transcript entry.
///
/// Calibrated 2026-11-03 against real transcripts in `~/.claude/projects`
/// (samples: "API Error: Stream ended without receiving any events"):
/// the CLI stamps them as synthetic assistant entries with top-level
/// `isApiErrorMessage: true`. Benign synthetics ("No response requested.")
/// carry the same key as `false` — only `true` counts. The text-prefix
/// fallback covers emitters that stamp the text but not the flag.
enum ApiErrorMarker {
    static func isApiError(_ entry: [String: Any]) -> Bool {
        guard (entry["type"] as? String) == "assistant" else { return false }
        if entry["isApiErrorMessage"] as? Bool == true {
            return true
        }
        guard let message = entry["message"] as? [String: Any] else { return false }
        return Self.text(of: message).hasPrefix("API Error")
    }

    private static func text(of message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let str = content as? String {
            return str
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }
}
