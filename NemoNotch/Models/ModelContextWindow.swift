import Foundation

enum ModelContextWindow {
    static let limits: [String: Int] = [
        "mimo-v2-pro": 1_000_000,
        "glm-5.1": 200_000,
    ]
    static let defaultValue = 200_000

    static func limit(for model: String) -> Int {
        limits[model] ?? defaultValue
    }
}
