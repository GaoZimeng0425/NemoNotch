import Foundation

enum ModelContextWindow {
    static let limits: [String: Int] = [
        "gemini-3-flash": 1_048_576,
        "gemini-3-flash-preview": 1_048_576,
        "gemini-3-pro": 2_097_152,
        "gemini-3-pro-preview": 2_097_152,
        "gemini-3.5-flash": 2_097_152,
        "gemini-3.5-pro": 4_194_304,
        "mimo-v2-pro": 1_000_000,
        "glm-5.1": 200_000,
        "glm-5.2": 1_000_000,
    ]
    static let defaultValue = 200_000

    static func limit(for model: String) -> Int {
        if let exact = limits[model] { return exact }
        // Claude model ids are versioned/dated (e.g. "claude-opus-4-1-20250805",
        // "claude-sonnet-4-5-20250929"); match Opus/Sonnet by family rather than
        // enumerating every dated variant. Both support a 1M context window.
        let lowered = model.lowercased()
        if lowered.contains("opus") || lowered.contains("sonnet") {
            return 1_048_576
        }
        return defaultValue
    }
}
