import HESHShared
import SwiftUI
import WebRTC

/// Schermata di chiamata in-app. CallKit mostra la sua a schermo bloccato; qui
/// video remoto a tutto schermo, anteprima locale, controlli.
struct CallView: View {
    @Environment(Theme.self) private var theme
    @State private var now = Date()
    private var svc: CallService { CallService.shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if svc.remoteHasVideo, let track = svc.remoteVideoTrack {
                VideoView(track: track).ignoresSafeArea()
            } else {
                HESHBackground()
                VStack(spacing: 14) {
                    Avatar(name: svc.call?.peer ?? "?", size: 110)
                    Text(svc.call?.peer ?? "").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).monospacedDigit()
                }
                .offset(y: -60)
            }

            if svc.cameraOn, let local = svc.localVideoTrack {
                VideoView(track: local, mirror: true)
                    .frame(width: 110, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.3)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(20)
                    .onTapGesture { svc.flipCamera() }
            }

            VStack {
                if svc.remoteHasVideo {
                    VStack(spacing: 2) {
                        Text(svc.call?.peer ?? "").font(.system(size: 18, weight: .semibold))
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity)
                }
                Spacer()
                HStack(spacing: 22) {
                    if svc.state == .incoming {
                        RoundButton(icon: "phone.down.fill", tint: Theme.danger) { svc.hangUp() }
                        RoundButton(icon: "phone.fill", tint: theme.accent, fg: .black) { svc.answer() }
                    } else {
                        RoundButton(icon: svc.muted ? "mic.slash.fill" : "mic.fill", tint: svc.muted ? .white : .white.opacity(0.18), fg: svc.muted ? .black : .white) { svc.muted.toggle() }
                        RoundButton(icon: svc.cameraOn ? "video.fill" : "video.slash.fill", tint: svc.cameraOn ? .white : .white.opacity(0.18), fg: svc.cameraOn ? .black : .white) { svc.cameraOn.toggle() }
                        RoundButton(icon: svc.speaker ? "speaker.wave.3.fill" : "speaker.wave.1.fill", tint: svc.speaker ? .white : .white.opacity(0.18), fg: svc.speaker ? .black : .white) { svc.speaker.toggle() }
                        RoundButton(icon: "phone.down.fill", tint: Theme.danger) { svc.hangUp() }
                    }
                }
                .padding(.bottom, 40)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var subtitle: String {
        if svc.state == .active, let s = svc.call?.connectedAt {
            let d = Int(now.timeIntervalSince(s))
            return String(format: "%02d:%02d", d / 60, d % 60)
        }
        return svc.statusText
    }
}

private struct RoundButton: View {
    let icon: String
    let tint: Color
    var fg: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(fg)
                .frame(width: 66, height: 66).background(Circle().fill(tint))
        }
    }
}

/// RTCMTLVideoView in SwiftUI.
struct VideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    var mirror = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        if mirror { v.transform = CGAffineTransform(scaleX: -1, y: 1) }
        track.add(v)
        context.coordinator.track = track
        return v
    }

    func updateUIView(_ v: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(v)
            track.add(v)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) { coordinator.track?.remove(v) }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}
