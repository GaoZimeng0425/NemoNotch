import Foundation

struct AppItem: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var bundleIdentifier: String

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}
