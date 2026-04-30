import AppKit
@preconcurrency import Foundation

private struct NowPlayingInfoBox: @unchecked Sendable {
    let info: [String: Any]?
    init(info: [String: Any]?) { self.info = info }
}

@MainActor
@Observable
final class MediaService {
    var playbackState = PlaybackState()
    var appIcon: NSImage?

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
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            self?.updateNowPlaying()
        }
    }

    func nextTrack() {
        remote.sendCommand(.nextTrack)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            self?.updateNowPlaying()
        }
    }

    func previousTrack() {
        remote.sendCommand(.previousTrack)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            self?.updateNowPlaying()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
            progressTimer?.invalidate()
        }
    }

    private func setupNotifications() {
        let nc = DistributedNotificationCenter.default()

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("com.apple.Music.playerInfo"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }
    }

    private func startProgressTick() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
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
    }

    private func updateNowPlaying() {
        if isUpdatingNowPlaying {
            needsFollowupUpdate = true
            return
        }

        isUpdatingNowPlaying = true

        nowPlayingCLI.fetchNowPlayingInfo { [weak self] cliInfo in
            let box = NowPlayingInfoBox(info: cliInfo)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyInfo(box.info)
                self.isUpdatingNowPlaying = false
                if self.needsFollowupUpdate {
                    self.needsFollowupUpdate = false
                    self.updateNowPlaying()
                }
            }
        }
    }

    private static func hasMetadata(_ info: [String: Any]) -> Bool {
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        return !(title.isEmpty && artist.isEmpty)
    }

    private func applyInfo(_ info: [String: Any]?) {
        guard let info, !info.isEmpty else {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
                appIcon = nil
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
                appIcon = nil
            }
            return
        }

        let bundleID = info["kMRMediaRemoteNowPlayingInfoParentAppBundleID"] as? String
            ?? info["kMRMediaRemoteNowPlayingInfoAppBundleID"] as? String

        playbackState = PlaybackState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            artworkData: artworkData,
            appBundleIdentifier: bundleID ?? playbackState.appBundleIdentifier,
            appName: nil
        )

        if let bundleID, !bundleID.isEmpty {
            applyPlayingApp(bundleID: bundleID)
        }
    }

    private func applyPlayingApp(bundleID: String) {
        playbackState.appBundleIdentifier = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
            playbackState.appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        }
    }
}
