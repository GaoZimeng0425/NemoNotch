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
    ]
    static let defaultValue = 200_000

    static func limit(for model: String) -> Int {
        limits[model] ?? defaultValue
    }
}
