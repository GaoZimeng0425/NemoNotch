import SwiftUI

struct NowPlayingSection: View {
    @Environment(MediaService.self) private var mediaService

    var body: some View {
        if mediaService.playbackState.isPlaying {
            Text(nowPlayingTitle)
                .disabled(true)
            Button("menu.previous_track") {
                mediaService.previousTrack()
            }
            Button("menu.play_pause") {
                mediaService.togglePlayPause()
            }
            Button("menu.next_track") {
                mediaService.nextTrack()
            }
            Divider()
        }
    }

    private var nowPlayingTitle: String {
        let state = mediaService.playbackState
        if state.artist.isEmpty {
            return "♫ \(state.title)"
        }
        return "♫ \(state.title) — \(state.artist)"
    }
}
