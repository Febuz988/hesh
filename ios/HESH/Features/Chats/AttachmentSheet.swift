import AVFoundation
import HESHShared
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Menu allegati: foto/video dalla libreria, fotocamera, file, vocale, posizione.
struct AttachmentSheet: View {
    let chat: Chat
    let onSend: (Content) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(Theme.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var busy = false
    @State private var progress = ""
    @State private var error: String?
    @State private var recorder = VoiceRecorder()

    var body: some View {
        ZStack {
            HESHBackground()
            VStack(spacing: 16) {
                Capsule().fill(Color.primary.opacity(0.2)).frame(width: 40, height: 4).padding(.top, 8)

                GlassCard(radius: 18) {
                    HStack(spacing: 12) {
                        Button { toggleRecording() } label: {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 20)).foregroundStyle(Color.heshInk)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Theme.danger))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recorder.isRecording ? "Registrazione in corso · \(recorder.seconds) s" : recorder.hasRecording ? "Vocale pronto · \(recorder.seconds) s" : "Messaggio vocale")
                                .font(.system(size: 14, weight: .semibold))
                            if recorder.isRecording {
                                HStack(spacing: 4) { Circle().fill(Theme.danger).frame(width: 8, height: 8); Text("Indicatore registrazione attivo").font(.system(size: 11)).foregroundStyle(Color.heshMuted(scheme)) }
                            }
                        }
                        Spacer()
                        if recorder.hasRecording, !recorder.isRecording {
                            Button("Ascolta") { recorder.play() }.font(.system(size: 13))
                            Button("Invia") { Task { await sendVoice() } }.font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                            Button { recorder.discard() } label: { Image(systemName: "xmark") }
                        }
                    }
                    .padding(12)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) { tile("Foto", "photo.on.rectangle") }
                    Button { showCamera = true } label: { tile("Fotocamera", "camera") }
                    Button { showFiles = true } label: { tile("File", "doc") }
                    Button { dismiss() } label: { tile("Posizione", "mappin.and.ellipse") }
                }

                if busy { ProgressView(progress).tint(theme.accent) }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                Spacer()
            }
            .padding(16)
        }
        .presentationDetents([.medium])
        .presentationBackground(.clear)
        .onChange(of: photoItem) { _, item in guard let item else { return }; Task { await sendPhoto(item) } }
        .sheet(isPresented: $showCamera) { CameraPicker { data in Task { await send(data, mime: "image/jpeg", name: nil) } } }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await sendFile(url) } }
        }
    }

    private func tile(_ label: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(theme.accent)
            Text(label).font(.system(size: 12)).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12))))
    }

    private func toggleRecording() {
        if recorder.isRecording { recorder.stop() } else { recorder.start() }
    }

    private func sendVoice() async {
        guard let data = recorder.data else { return }
        await send(data, mime: "audio/m4a", name: nil, duration: Double(recorder.seconds))
        recorder.discard()
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        busy = true; progress = "Preparazione"
        defer { busy = false }
        do {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let data = try await item.loadTransferable(type: Data.self) { await send(data, mime: "video/mp4", name: nil) }
            } else if let data = try await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                let resized = img.resized(maxSide: 1600)
                if let jpeg = resized.jpegData(compressionQuality: 0.82) { await send(jpeg, mime: "image/jpeg", name: nil) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func sendFile(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            await send(data, mime: mime, name: url.lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }

    private func send(_ data: Data, mime: String, name: String?, duration: Double? = nil) async {
        busy = true; progress = "Cifratura e caricamento"
        defer { busy = false }
        do {
            let up = try await AttachmentService.shared.upload(data)
            try await onSend(.attachment(chat: chat.id, up: up, mime: mime, name: name, caption: nil, durationS: duration, ephemeralS: chat.ephemeralS))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage, let data = img.resized(maxSide: 1600).jpegData(compressionQuality: 0.82) { parent.onImage(data) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Registrazione vocale in AAC. Indicatore visibile sempre durante la registrazione.
@Observable
@MainActor
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isRecording = false
    var seconds = 0
    var data: Data?
    var hasRecording: Bool { data != nil }
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice.m4a")

    func start() {
        AVAudioApplication.requestRecordPermission { ok in
            guard ok else { return }
            Task { @MainActor in self.begin() }
        }
    }

    private func begin() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        isRecording = true
        seconds = 0
        data = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.seconds += 1 } }
    }

    func stop() {
        recorder?.stop()
        timer?.invalidate()
        isRecording = false
        data = try? Data(contentsOf: url)
    }

    func play() {
        guard let data else { return }
        player = try? AVAudioPlayer(data: data)
        player?.play()
    }

    func discard() {
        data = nil
        seconds = 0
        try? FileManager.default.removeItem(at: url)
    }
}
