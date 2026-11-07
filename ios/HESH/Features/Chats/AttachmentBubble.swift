import AVFoundation
import HESHShared
import QuickLook
import SwiftUI

/// Rende un messaggio di tipo attachment: anteprima foto, player vocale, scheda file.
struct AttachmentBubble: View {
    let content: Content
    let mine: Bool
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var localURL: URL?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var preview: URL?
    @State private var player = VoicePlayer()

    var body: some View {
        Group {
            if content.isImage {
                imageView
            } else if content.isVoice {
                voiceView
            } else {
                fileView
            }
        }
        .task(id: content.attId) { await load() }
        .quickLookPreview($preview)
    }

    private var imageView: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 220, height: 220).clipped()
                    .onTapGesture { preview = localURL }
            } else {
                RoundedRectangle(cornerRadius: 0).fill(Color.primary.opacity(0.08)).frame(width: 220, height: 220)
                    .overlay { if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger) } else { ProgressView() } }
            }
        }
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: mine ? 20 : 6, bottomTrailing: mine ? 6 : 20, topTrailing: 20), style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Label("cifrata", systemImage: "lock.fill").font(.system(size: 10))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.heshInk.opacity(0.6))).foregroundStyle(.white)
                .padding(8)
        }
    }

    private var voiceView: some View {
        HStack(spacing: 10) {
            Button {
                if let localURL { player.toggle(url: localURL) }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14)).foregroundStyle(Color.heshInk)
                    .frame(width: 34, height: 34).background(Circle().fill(theme.accent))
            }
            .disabled(localURL == nil)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<18, id: \.self) { i in
                    Capsule().fill(Double(i) / 18 < player.progress ? theme.accent : Color.heshMuted(scheme).opacity(0.6))
                        .frame(width: 3, height: CGFloat(6 + (i * 7 % 17)))
                }
            }
            .frame(height: 22)
            Text(duration).font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minWidth: 200)
        .background(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: mine ? 20 : 6, bottomTrailing: mine ? 6 : 20, topTrailing: 20), style: .continuous)
            .fill(mine ? theme.accent.opacity(0.25) : Color.primary.opacity(0.08)))
    }

    private var fileView: some View {
        Button { preview = localURL } label: {
            HStack(spacing: 12) {
                Image(systemName: content.isVideo ? "film" : "doc.fill").font(.system(size: 22)).foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.name ?? (content.isVideo ? "Video" : "File")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(sizeLabel).font(.system(size: 12)).foregroundStyle(Color.heshMuted(scheme))
                }
                Spacer(minLength: 0)
                if localURL == nil { ProgressView().scaleEffect(0.8) }
            }
            .padding(12).frame(width: 240)
            .background(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 20, bottomLeading: mine ? 20 : 6, bottomTrailing: mine ? 6 : 20, topTrailing: 20), style: .continuous)
                .fill(mine ? theme.accent.opacity(0.25) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(localURL == nil)
    }

    private var duration: String {
        let s = Int(content.durationS ?? 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(content.size ?? 0), countStyle: .file)
    }

    private func load() async {
        guard let id = content.attId, let key = content.key, let digest = content.digest else { failed = true; return }
        do {
            let url = try await AttachmentService.shared.fetch(attId: id, key: key, digest: digest)
            localURL = url
            if content.isImage { image = UIImage(contentsOfFile: url.path) }
        } catch { failed = true }
    }
}

@Observable
@MainActor
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isPlaying = false
    var progress: Double = 0

    func toggle(url: URL) {
        if isPlaying { player?.pause(); isPlaying = false; timer?.invalidate(); return }
        if player == nil || player?.url != url {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        player?.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let p = self.player else { return }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false; self.progress = 0; self.timer?.invalidate() }
    }
}
