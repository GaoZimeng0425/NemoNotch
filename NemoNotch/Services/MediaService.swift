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
    /// When non-nil, UI surfaces a banner prompting the user to grant
    /// Automation permission for this player in System Settings.
    var permissionDeniedPlayer: KnownPlayer?

    private var pollTimer: Timer?
    private var progressTimer: Timer?
    private var reconcileTask: Task<Void, Never>?
    private var isUpdatingNowPlaying = false
    private var needsFollowupUpdate = false
    private let remote = MediaRemote.shared
    private let nowPlayingCLI = NowPlayingCLI()

    // ── Reconcile guard ──────────────────────────────────────────────
    // After an optimistic toggle we set `reconcileExpectedIsPlaying` to
    // the value we expect.  `applyInfo` must preserve it until
    // `reconcilePlayState` clears the flag and queries the authoritative
    // source (ScriptingBridge for known players, CLI otherwise).
    private var reconcileExpectedIsPlaying: Bool?

    init() {
        remote.registerForNotifications()
        remote.setCanBeNowPlayingApplication(false)
        MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
            guard let self, let player = KnownPlayer(bundleID: bundleID) else { return }
            self.permissionDeniedPlayer = player
        }
        setupNotifications()
        startPolling()
        updateNowPlaying()
    }

    func dismissPermissionBanner() {
        permissionDeniedPlayer = nil
    }

    func openAutomationSettings() {
        MediaBridge.openAutomationSettings()
        permissionDeniedPlayer = nil
    }

    // ── Player controls ──────────────────────────────────────────────

    func togglePlayPause() {
        let bundleID = playbackState.appBundleIdentifier
        let target = !playbackState.isPlaying
        LogService.debug("[Media] toggle: \(playbackState.isPlaying) → \(target), player=\(bundleID ?? "nil")", category: "media")
        playbackState.isPlaying = target
        reconcileExpectedIsPlaying = target
        updateProgressTimer(isPlaying: target)
        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.togglePlayPause(bundleID: bundleID)
        } else {
            remote.sendCommand(.togglePlayPause)
        }
        scheduleReconcile(after: 0.5)
    }

    func nextTrack() {
        let bundleID = playbackState.appBundleIdentifier
        applyTrackChangePlaceholder()
        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.nextTrack(bundleID: bundleID)
        } else {
            remote.sendCommand(.nextTrack)
        }
        scheduleReconcile(after: 0.6)
    }

    func previousTrack() {
        let bundleID = playbackState.appBundleIdentifier
        applyTrackChangePlaceholder()
        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.previousTrack(bundleID: bundleID)
        } else {
            remote.sendCommand(.previousTrack)
        }
        scheduleReconcile(after: 0.6)
    }

    private func applyTrackChangePlaceholder() {
        playbackState.position = 0
        playbackState.duration = 0
    }

    // ── Reconcile ────────────────────────────────────────────────────
    // The reconcile is the ONLY place that clears the optimistic guard
    // and queries the *authoritative* play state.

    private func scheduleReconcile(after seconds: TimeInterval) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.reconcilePlayState()
        }
    }

    /// Queries the authoritative play state and keeps the guard set to the
    /// SB value. The guard self-clears in `applyInfo` once CLI catches up.
    private func reconcilePlayState() {
        let bundleID = playbackState.appBundleIdentifier
        LogService.debug("[Media] reconcile: player=\(bundleID ?? "nil")", category: "media")

        // For known players (Spotify / Music) query ScriptingBridge
        // directly — synchronous, zero cache, authoritative.
        if let playing = MediaBridge.isPlaying(bundleID: bundleID) {
            LogService.debug("[Media] reconcile: ScriptingBridge isPlaying=\(playing), was=\(playbackState.isPlaying)", category: "media")
            playbackState.isPlaying = playing
            updateProgressTimer(isPlaying: playing)
            // Keep guard set to SB value — applyInfo will auto-clear it
            // once CLI returns a matching value. This prevents stale CLI
            // data from overwriting the authoritative SB state.
            reconcileExpectedIsPlaying = playing
        } else {
            LogService.debug("[Media] reconcile: unknown player, falling back to CLI", category: "media")
            reconcileExpectedIsPlaying = nil
            updateNowPlaying()
        }
    }

    // ── Seek ─────────────────────────────────────────────────────────

    var supportsSeeking: Bool {
        MediaBridge.supportsSeeking(bundleID: playbackState.appBundleIdentifier)
    }

    func skipForward(_ interval: Double = 15) {
        seek(by: interval)
    }

    func skipBackward(_ interval: Double = 15) {
        seek(by: -interval)
    }

    func seek(toFraction fraction: Double) {
        guard playbackState.duration > 0 else { return }
        let target = max(0, min(playbackState.duration, fraction * playbackState.duration))
        seek(toAbsolute: target)
    }

    private func seek(by interval: Double) {
        guard playbackState.duration > 0 else { return }
        let target = max(0, min(playbackState.position + interval, playbackState.duration))
        seek(toAbsolute: target, fallbackInterval: interval)
    }

    private func seek(toAbsolute target: Double, fallbackInterval: Double? = nil) {
        let bundleID = playbackState.appBundleIdentifier
        playbackState.position = target

        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.setPlayerPosition(bundleID: bundleID, position: target)
        } else if remote.setElapsedTime(target) {
            // ok
        } else if let interval = fallbackInterval {
            remote.skip(interval: interval)
        }

        scheduleReconcile(after: 0.5)
    }

    deinit {
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
            progressTimer?.invalidate()
            reconcileTask?.cancel()
        }
    }

    // ── Notifications ────────────────────────────────────────────────
    // All notifications go through the same simple updateNowPlaying path.
    // The reconcile guard in applyInfo prevents stale CLI data from
    // overriding the optimistic isPlaying during the reconcile window.

    private func setupNotifications() {
        let nc = DistributedNotificationCenter.default()

        let names: [NSNotification.Name] = [
            .init("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            .init("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            .init("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            .init("com.spotify.client.PlaybackStateChanged"),
            .init("com.apple.Music.playerInfo"),
        ]

        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    LogService.debug("[Media] notification: \(name.rawValue)", category: "media")
                    self?.updateNowPlaying()
                }
            }
        }
    }

    // ── Polling ──────────────────────────────────────────────────────

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                LogService.debug("[Media] poll timer", category: "media")
                self?.updateNowPlaying()
                self?.recheckPermissionIfBannerShown()
            }
        }
    }

    private func recheckPermissionIfBannerShown() {
        guard let player = permissionDeniedPlayer else { return }
        if MediaBridge.hasAutomationAccess(bundleID: player.rawValue) {
            permissionDeniedPlayer = nil
        }
    }

    // ── Progress timer ───────────────────────────────────────────────

    private func updateProgressTimer(isPlaying: Bool) {
        if isPlaying && progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackState.isPlaying, self.playbackState.duration > 0 else { return }
                    let next = min(self.playbackState.duration, self.playbackState.position + 0.5)
                    if next > self.playbackState.position { self.playbackState.position = next }
                }
            }
        } else if !isPlaying && progressTimer != nil {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    // ── Core data fetch ──────────────────────────────────────────────

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

    // ── Apply fetched data to UI state ───────────────────────────────

    private func applyInfo(_ info: [String: Any]?) {
        guard let info, !info.isEmpty else {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
                appIcon = nil
            }
            updateProgressTimer(isPlaying: false)
            return
        }

        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
        var position = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0

        // ── isPlaying resolution ──────────────────────────────────
        // Guard protects isPlaying from stale CLI data. Once CLI returns
        // a value that matches the guard, the guard self-clears — CLI has
        // caught up and is safe to trust again.
        let cliPlaying = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0 > 0
        let resolvedIsPlaying: Bool
        if let expected = reconcileExpectedIsPlaying {
            if cliPlaying == expected {
                // CLI has caught up — safe to drop the guard.
                reconcileExpectedIsPlaying = nil
                resolvedIsPlaying = cliPlaying
                LogService.debug("[Media] applyInfo: guard lifted, CLI caught up (=\(cliPlaying)), title=\(title)", category: "media")
            } else {
                resolvedIsPlaying = expected
                LogService.debug("[Media] applyInfo: guarded, expected=\(expected), cli=\(cliPlaying), title=\(title)", category: "media")
            }
        } else {
            resolvedIsPlaying = cliPlaying
            LogService.debug("[Media] applyInfo: from CLI, isPlaying=\(cliPlaying), title=\(title)", category: "media")
        }

        if resolvedIsPlaying, let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
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
            updateProgressTimer(isPlaying: false)
            return
        }

        let bundleID = info["kMRMediaRemoteNowPlayingInfoParentAppBundleID"] as? String
            ?? info["kMRMediaRemoteNowPlayingInfoAppBundleID"] as? String

        let previousBundleID = playbackState.appBundleIdentifier
        let resolvedBundleID = bundleID ?? previousBundleID

        playbackState = PlaybackState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            isPlaying: resolvedIsPlaying,
            artworkData: artworkData,
            appBundleIdentifier: resolvedBundleID,
            appName: nil
        )

        if let resolvedBundleID, !resolvedBundleID.isEmpty {
            applyPlayingApp(bundleID: resolvedBundleID, changed: resolvedBundleID != previousBundleID)
        }
        updateProgressTimer(isPlaying: resolvedIsPlaying)
    }

    private func applyPlayingApp(bundleID: String, changed: Bool) {
        guard changed else { return }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
            playbackState.appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        } else {
            appIcon = nil
        }
        MediaBridge.requestPermissionIfNeeded(bundleID: bundleID)
    }
}
