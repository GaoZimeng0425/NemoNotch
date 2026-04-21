import SwiftUI

struct MediaTab: View {
    @Environment(MediaService.self) var mediaService

    private var state: PlaybackState { mediaService.playbackState }

    var body: some View {
        if state.isEmpty {
            emptyState
        } else {
            playingState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("未在播放")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playingState: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                artwork
                trackInfo
                Spacer(minLength: 0)
            }

            progressBar

            controls
        }
        .padding(.horizontal, 4)
    }

    private var artwork: some View {
        Group {
            if let data = state.artworkData,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(state.artist)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: state.duration > 0 ? geo.size.width * CGFloat(state.position / state.duration) : 0)
            }
        }
        .frame(height: 3)
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button(action: { mediaService.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Button(action: { mediaService.togglePlayPause() }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)

            Button(action: { mediaService.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }
}
