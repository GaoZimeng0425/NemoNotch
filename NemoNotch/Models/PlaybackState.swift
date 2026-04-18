import Foundation

struct PlaybackState: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: TimeInterval = 0
    var position: TimeInterval = 0
    var isPlaying: Bool = false
    var artworkData: Data?

    var isEmpty: Bool { title.isEmpty }
}
