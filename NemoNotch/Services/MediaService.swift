import AppKit
@preconcurrency import Foundation
import SwiftUI

private struct NowPlayingInfoBox: @unchecked Sendable {
    let info: [String: Any]?
}

@MainActor
@Observable
final class MediaService {
    var playbackState = PlaybackState()
    /// 播放位置(秒),独立于 `playbackState` 元数据。每 0.5s 由 progressTimer 前进,
    /// 频繁变化但只被进度条/时间标签消费 —— 拆出来避免触发读元数据(isPlaying/title 等)
    /// 的视图(NotchView/BadgeIconView)随 position 重算。
    var playbackPosition: TimeInterval = 0
    var appIcon: NSImage?
    /// Dominant color of the current artwork, extracted off the main actor on
    /// every artwork change. `nil` when there is no artwork or it is
    /// effectively grayscale — consumers fall back to `NotchTheme.accent`.
    var artworkAccent: Color?

    private var artworkAccentTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var progressTimer: Timer?
    private var reconcileTask: Task<Void, Never>?
    private var isUpdatingNowPlaying = false
    private var needsFollowupUpdate = false
    private let remote = MediaRemote.shared
    private let nowPlayingCLI = NowPlayingCLI()
    private let commander = MediaRemoteCommander()

    // ── Reconcile guard ──────────────────────────────────────────────
    // After an optimistic toggle we set `reconcileExpectedIsPlaying` to the
    // value we expect. `applyInfo` preserves it until the CLI poll catches up
    // (its reported playback rate matches) or the hard expiry passes, whichever
    // comes first — so the UI never lags, flickers on a stale poll, or sticks.
    private var reconcileExpectedIsPlaying: Bool?
    private var reconcileGuardExpiresAt: Date?
    private static let guardMaxDuration: TimeInterval = 3.0

    init(disableLiveUpdates: Bool = false) {
        remote.registerForNotifications()
        remote.setCanBeNowPlayingApplication(false)
        guard !disableLiveUpdates else {
            LogService.info("MediaService init (uitest: live updates disabled)", category: "MediaService")
            return
        }
        setupNotifications()
        startPolling()
        startProgressTimer()
        updateNowPlaying()
    }

    // ── Player controls ──────────────────────────────────────────────

    func togglePlayPause() {
        let bundleID = playbackState.appBundleIdentifier
        let target = !playbackState.isPlaying
        LogService.debug(
            "[Media] toggle: \(playbackState.isPlaying) → \(target), player=\(bundleID ?? "nil")",
            category: "media"
        )
        playbackState.isPlaying = target
        reconcileExpectedIsPlaying = target
        reconcileGuardExpiresAt = Date().addingTimeInterval(Self.guardMaxDuration)
        commander.togglePlayPause()
        scheduleReconcile(after: 0.5)
    }

    func nextTrack() {
        applyTrackChangePlaceholder()
        commander.nextTrack()
        scheduleReconcile(after: 0.6)
    }

    func previousTrack() {
        applyTrackChangePlaceholder()
        commander.previousTrack()
        scheduleReconcile(after: 0.6)
    }

    private func applyTrackChangePlaceholder() {
        playbackPosition = 0
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

    /// Triggers a fresh CLI fetch shortly after an optimistic action. The guard
    /// in `applyInfo` does the actual correction: it holds the optimistic value
    /// until the CLI's reported playback rate agrees (or the hard expiry hits),
    /// so a single stale poll can't flicker the button back.
    private func reconcilePlayState() {
        LogService.debug("[Media] reconcile: refresh from CLI (guard self-heals in applyInfo)", category: "media")
        updateNowPlaying()
    }

    // ── Seek ─────────────────────────────────────────────────────────

    /// Seeking works for any player with a finite timeline — control now goes
    /// through `MediaRemoteCommander.setTime` (the perl bridge), which drives
    /// `MRMediaRemoteSetElapsedTime` and is honored by Music, Spotify, browsers,
    /// Podcasts, etc. Live streams report `duration == 0`, where seek is moot.
    var supportsSeeking: Bool {
        playbackState.duration > 0
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
        let target = max(0, min(playbackPosition + interval, playbackState.duration))
        seek(toAbsolute: target)
    }

    private func seek(toAbsolute target: Double) {
        playbackPosition = target
        commander.setTime(seconds: target)
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
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
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
                PerfProbe.hit("MediaService.pollTick@2s")
                self?.updateNowPlaying()
            }
        }
    }

    // ── Progress timer ───────────────────────────────────────────────
    // 常驻 timer:回调里按需前进 playbackPosition,避免反复启停(旧版 updateProgressTimer
    // 被多处调用导致 timer 反复销毁重建,实测每秒触发数远超 0.5s 间隔)。

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                PerfProbe.hit("MediaService.progressTick@0.5s")
                guard let self,
                      playbackState.isPlaying,
                      playbackState.duration > 0 else { return }
                let next = min(playbackState.duration, playbackPosition + 0.5)
                if next > playbackPosition {
                    // 这一次赋值会驱动订阅了播放进度的视图重绘。
                    PerfProbe.hit("MediaService.progressAdvance")
                    playbackPosition = next
                }
            }
        }
    }

    // ── Core data fetch ──────────────────────────────────────────────

    private func updateNowPlaying() {
        PerfProbe.hit("MediaService.updateNowPlaying")
        if isUpdatingNowPlaying {
            needsFollowupUpdate = true
            PerfProbe.hit("MediaService.updateNowPlaying.coalesced")
            return
        }

        isUpdatingNowPlaying = true

        nowPlayingCLI.fetchNowPlayingInfo { [weak self] cliInfo in
            let box = NowPlayingInfoBox(info: cliInfo)
            DispatchQueue.main.async {
                guard let self else { return }
                let applyProbe = PerfProbe.begin()
                self.applyInfo(box.info)
                PerfProbe.end("MediaService.applyInfo(含封面解码)", applyProbe)
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
                updateArtworkAccent(nil, changed: true)
            }
            playbackPosition = 0
            return
        }

        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
        var position = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0

        // ── isPlaying resolution ──────────────────────────────────
        // Guard protects isPlaying from stale CLI data. It drops when
        // Guard protects isPlaying from stale CLI data. It drops when
        // (a) CLI catches up (matches the expected value) or
        // (b) `guardMaxDuration` elapses without agreement (CLI takes over).
        let cliPlaying = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0 > 0
        let resolvedIsPlaying: Bool
        if let expected = reconcileExpectedIsPlaying {
            let expired = (reconcileGuardExpiresAt.map { Date() > $0 }) ?? false
            if cliPlaying == expected {
                reconcileExpectedIsPlaying = nil
                reconcileGuardExpiresAt = nil
                resolvedIsPlaying = cliPlaying
                LogService.debug(
                    "[Media] applyInfo: guard lifted, CLI caught up (=\(cliPlaying)), title=\(title)",
                    category: "media"
                )
            } else if expired {
                reconcileExpectedIsPlaying = nil
                reconcileGuardExpiresAt = nil
                resolvedIsPlaying = cliPlaying
                LogService.debug(
                    "[Media] applyInfo: guard expired after \(Self.guardMaxDuration)s, falling back to CLI (=\(cliPlaying)), title=\(title)",
                    category: "media"
                )
            } else {
                resolvedIsPlaying = expected
                LogService.debug(
                    "[Media] applyInfo: guarded, expected=\(expected), cli=\(cliPlaying), title=\(title)",
                    category: "media"
                )
            }
        } else {
            resolvedIsPlaying = cliPlaying
            LogService.debug("[Media] applyInfo: from CLI, isPlaying=\(cliPlaying), title=\(title)", category: "media")
        }

        if resolvedIsPlaying, let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
            let elapsed = Date().timeIntervalSince(timestamp)
            position = max(0, position + elapsed)
            if duration > 0 {
                position = min(position, duration)
            }
        }
        // position 同步到独立属性(每秒最多 1 次,且只被进度条消费)。
        playbackPosition = position

        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

        if title.isEmpty, artist.isEmpty {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
                appIcon = nil
                updateArtworkAccent(nil, changed: true)
            }
            playbackPosition = 0
            return
        }

        let bundleID = info["kMRMediaRemoteNowPlayingInfoParentAppBundleID"] as? String
            ?? info["kMRMediaRemoteNowPlayingInfoAppBundleID"] as? String

        let previousBundleID = playbackState.appBundleIdentifier
        let resolvedBundleID = bundleID ?? previousBundleID
        let previousArtworkData = playbackState.artworkData

        // Equatable 去重:元数据没变就不写,避免触发读元数据的视图重算。
        let next = PlaybackState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            isPlaying: resolvedIsPlaying,
            artworkData: artworkData,
            appBundleIdentifier: resolvedBundleID,
            appName: nil
        )
        if next != playbackState {
            playbackState = next
        }

        if let resolvedBundleID, !resolvedBundleID.isEmpty {
            applyPlayingApp(bundleID: resolvedBundleID, changed: resolvedBundleID != previousBundleID)
        }
        updateArtworkAccent(artworkData, changed: artworkData != previousArtworkData)
    }

    /// Recompute `artworkAccent` when the artwork bytes change. The pixel
    /// scan runs detached off the main actor; a newer artwork cancels any
    /// in-flight extraction.
    private func updateArtworkAccent(_ data: Data?, changed: Bool) {
        guard changed else { return }
        artworkAccentTask?.cancel()
        artworkAccentTask = nil
        guard let data else {
            artworkAccent = nil
            return
        }
        artworkAccentTask = Task { [weak self] in
            let color = await Task.detached(priority: .utility) {
                ArtworkColor.accent(from: data)
            }.value
            guard let self, !Task.isCancelled else { return }
            artworkAccent = color
            LogService.debug("[Media] artwork accent extracted: \(color.map { "\($0)" } ?? "nil")", category: "media")
        }
    }

    private func applyPlayingApp(bundleID: String, changed: Bool) {
        guard changed else { return }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
            playbackState.appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?
                .localizedName
        } else {
            appIcon = nil
        }
    }
}
