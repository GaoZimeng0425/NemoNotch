import Foundation
import MediaRemoteAdapter

/// Sends system-wide media control commands (play/pause/skip/seek) through the
/// `mediaremote-adapter` Perl bridge.
///
/// Since macOS 15.4 Apple gated the private `MediaRemote.framework` control
/// functions (`MRMediaRemoteSendCommand`, `MRMediaRemoteSetElapsedTime`, …) to
/// Apple-signed / entitled processes, so calling them *in-process* from a
/// third-party app (the `MediaRemote.swift` path) silently no-ops. The adapter
/// spawns the Apple-signed `/usr/bin/perl`, which `dlopen`s the framework and
/// issues the command on our behalf — the signature check sees Perl, so it
/// passes. This is the same bypass NemoNotch already uses for *reads* via
/// `NowPlayingCLI`; here it covers *control* for any player that reports Now
/// Playing info (browsers, Podcasts, etc.). Spotify / Music keep using
/// ScriptingBridge (`MediaBridge`) — they need AppleScript for seek anyway.
///
/// Commands work without `startListening()`: `MediaController` writes to a live
/// listener's stdin if present, otherwise spawns a one-shot `perl run.pl`. We
/// only need the one-shot path, so no background listener is started.
@MainActor
final class MediaRemoteCommander {
    private let controller = MediaController()

    init() {
        LogService.info("MediaRemoteCommander init (perl-bridge control)", category: "MediaRemoteCommander")
    }

    func togglePlayPause() {
        LogService.debug("send toggle_play_pause", category: "MediaRemoteCommander")
        controller.togglePlayPause()
    }

    func nextTrack() {
        LogService.debug("send next_track", category: "MediaRemoteCommander")
        controller.nextTrack()
    }

    func previousTrack() {
        LogService.debug("send previous_track", category: "MediaRemoteCommander")
        controller.previousTrack()
    }

    /// Seek to an absolute elapsed time (seconds) via `set_time`.
    func setTime(seconds: Double) {
        LogService.debug("send set_time \(seconds)s", category: "MediaRemoteCommander")
        controller.setTime(seconds: seconds)
    }
}
