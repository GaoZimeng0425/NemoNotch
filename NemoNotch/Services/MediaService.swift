import AppKit
import Foundation
import MediaPlayer

@Observable
final class MediaService {
    var playbackState = PlaybackState()

    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
    private var pollTimer: Timer?

    init() {
        updateNowPlaying()
        startPolling()
    }

    func togglePlayPause() {
        DistributedNotificationCenter.default().post(name: .init("com.apple.music.playpause"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateNowPlaying()
        }
    }

    func nextTrack() {
        DistributedNotificationCenter.default().post(name: .init("com.apple.music.next"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateNowPlaying()
        }
    }

    func previousTrack() {
        DistributedNotificationCenter.default().post(name: .init("com.apple.music.previous"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateNowPlaying()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        let info = nowPlayingCenter.nowPlayingInfo

        let title = info?[MPMediaItemPropertyTitle] as? String ?? ""
        let artist = info?[MPMediaItemPropertyArtist] as? String ?? ""
        let album = info?[MPMediaItemPropertyAlbumTitle] as? String ?? ""
        let duration = info?[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
        let position = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0

        let state = nowPlayingCenter.playbackState
        let isPlaying = state == .playing

        var artworkData: Data?
        if let artwork = info?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            let image = artwork.image(at: CGSize(width: 100, height: 100))
            artworkData = image?.tiffRepresentation
        }

        playbackState = PlaybackState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            artworkData: artworkData
        )
    }
}
