import AppKit
import Foundation

@Observable
final class MediaService {
    var playbackState = PlaybackState()

    private var pollTimer: Timer?
    private var progressTimer: Timer?
    private var isUpdatingNowPlaying = false
    private var needsFollowupUpdate = false
    private let remote = MediaRemote.shared
    private let nowPlayingCLI = NowPlayingCLI()

    init() {
        remote.registerForNotifications()
        remote.setCanBeNowPlayingApplication(false)
        setupNotifications()
        startPolling()
        startProgressTick()
        updateNowPlaying()
    }

    func togglePlayPause() {
        remote.sendCommand(.togglePlayPause)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateNowPlaying() }
    }

    func nextTrack() {
        remote.sendCommand(.nextTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateNowPlaying() }
    }

    func previousTrack() {
        remote.sendCommand(.previousTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateNowPlaying() }
    }

    deinit {
        pollTimer?.invalidate()
        progressTimer?.invalidate()
    }

    private func setupNotifications() {
        let nc = DistributedNotificationCenter.default()

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in self?.updateNowPlaying() }

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in self?.updateNowPlaying() }

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in self?.updateNowPlaying() }

        nc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"),
                       object: nil, queue: .main) { [weak self] _ in self?.updateNowPlaying() }

        nc.addObserver(forName: .init("com.apple.Music.playerInfo"),
                       object: nil, queue: .main) { [weak self] _ in self?.updateNowPlaying() }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateNowPlaying()
        }
    }

    private func startProgressTick() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.playbackState.isPlaying else { return }
            guard self.playbackState.duration > 0 else { return }
            guard !self.playbackState.isEmpty else { return }

            let nextPosition = min(self.playbackState.duration, self.playbackState.position + 0.5)
            if nextPosition > self.playbackState.position {
                self.playbackState.position = nextPosition
            }
        }
    }

    private func updateNowPlaying() {
        if isUpdatingNowPlaying {
            needsFollowupUpdate = true
            return
        }

        isUpdatingNowPlaying = true
        nowPlayingCLI.fetchNowPlayingInfo { [weak self] cliInfo in
            guard let self else { return }
            let finish: () -> Void = {
                self.isUpdatingNowPlaying = false
                if self.needsFollowupUpdate {
                    self.needsFollowupUpdate = false
                    self.updateNowPlaying()
                }
            }

            if let cliInfo {
                self.applyInfo(cliInfo)
                finish()
                return
            }
            finish()
        }
    }

    private func applyInfo(_ info: [String: Any]?) {
        guard let info, !info.isEmpty else {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
            }
            return
        }

        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
        var position = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0
        let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = playbackRate > 0

        if isPlaying, let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
            let elapsed = Date().timeIntervalSince(timestamp)
            position = max(0, position + elapsed)
            if duration > 0 { position = min(position, duration) }
        }

        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

        if title.isEmpty && artist.isEmpty {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
            }
            return
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
