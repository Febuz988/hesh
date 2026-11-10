import AVFoundation
import CallKit
import HESHShared
import PushKit
import SwiftUI
import WebRTC

/// Chiamate 1:1 audio/video. Segnalazione dentro le buste Signal (offer/answer/ICE),
/// media WebRTC cifrati (DTLS-SRTP) in diretta o via TURN su Sovrano. CallKit per
/// la schermata di sistema e l'audio in background, PushKit per squillare a app chiusa.
@Observable
@MainActor
final class CallService: NSObject {
    static let shared = CallService()

    enum State: Equatable { case idle, outgoing, incoming, connecting, active, ended }

    struct ActiveCall: Equatable {
        let uuid: UUID
        let callId: String
        let peer: String
        var video: Bool
        let outgoing: Bool
        var connectedAt: Date?
    }

    private(set) var call: ActiveCall?
    private(set) var state: State = .idle
    private(set) var statusText = ""
    var muted = false { didSet { audioTrack?.isEnabled = !muted } }
    var speaker = false { didSet { setSpeaker(speaker) } }
    var cameraOn = false { didSet { setCamera(cameraOn) } }
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteHasVideo = false

    private let provider: CXProvider
    private let controller = CXCallController()
    private let factory: RTCPeerConnectionFactory
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var frontCamera = true
    private var pendingOffer: Content?
    private var remoteCandidates: [RTCIceCandidate] = []
    private var ringTimer: Task<Void, Never>?
    private var voipPlaceholder: UUID?
    private var pushRegistry: PKPushRegistry?
    private var endedReasonSent = false

    private static let ringSeconds: UInt64 = 45
    /// Sul simulatore CallKit chiude le chiamate da solo (niente sessione audio telefonica):
    /// la chiamata vive solo nella schermata in-app.
    #if targetEnvironment(simulator)
    private static let useCallKit = false
    #else
    private static let useCallKit = true
    #endif

    override private init() {
        RTCInitializeSSL()
        let enc = RTCDefaultVideoEncoderFactory()
        let dec = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
        let cfg = CXProviderConfiguration()   // il nome mostrato e' quello dell'app: HESH
        cfg.supportsVideo = true
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.includesCallsInRecents = true
        cfg.ringtoneSound = "pulse.wav"
        if let img = UIImage(systemName: "checkmark.shield")?.withTintColor(.black, renderingMode: .alwaysTemplate) { cfg.iconTemplateImageData = img.pngData() }
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    /// Da chiamare all'avvio: collega la segnalazione e registra PushKit.
    func activate() {
        Task { await MessageService.shared.setCallHandler { [weak self] c, from in await self?.handleSignal(c, from: from) } }
        let reg = PKPushRegistry(queue: .main)
        reg.delegate = self
        reg.desiredPushTypes = [.voIP]
        pushRegistry = reg
    }

    // MARK: Uscente

    func startCall(to peer: String, video: Bool) {
        guard state == .idle else { return }
        let uuid = UUID()
        call = ActiveCall(uuid: uuid, callId: uuid.uuidString.lowercased(), peer: peer, video: video, outgoing: true)
        state = .outgoing
        statusText = "Chiamata in corso"
        guard Self.useCallKit else { Task { await startOrFail() }; return }
        let handle = CXHandle(type: .generic, value: peer)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = video
        controller.request(CXTransaction(action: action)) { [weak self] err in
            if let err { Task { @MainActor in self?.fail("CallKit: \(err.localizedDescription)") } }
        }
    }

    func hangUp() {
        guard let call else { return }
        guard Self.useCallKit else { Task { await performEnd() }; return }
        controller.request(CXTransaction(action: CXEndCallAction(call: call.uuid))) { _ in }
    }

    func answer() {
        guard let call, state == .incoming else { return }
        guard Self.useCallKit else { Task { await answerOrFail() }; return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: call.uuid))) { _ in }
    }

    // MARK: Azioni (chiamate da CallKit sul dispositivo, direttamente sul simulatore)

    private func performStart() async throws {
        guard let call else { throw CallError.peerConnection }
        configureAudioSession()
        try await makePeerConnection()
        guard let pc else { throw CallError.peerConnection }
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        await sendSignal(.callOffer, to: call.peer) { $0.sdp = offer.sdp; $0.video = call.video }
        if Self.useCallKit { provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: Date()) } else { RTCAudioSession.sharedInstance().isAudioEnabled = true }
        if call.video { cameraOn = true }
        startRingTimer { [weak self] in
            guard let self, self.state == .outgoing else { return }
            Task { await self.sendEndIfNeeded(reason: "timeout") }
            if Self.useCallKit { self.provider.reportCall(with: call.uuid, endedAt: Date(), reason: .unanswered) }
            self.teardown(status: "Nessuna risposta")
        }
    }

    private func startOrFail() async {
        do { try await performStart() } catch { fail(error.localizedDescription) }
    }

    private func performAnswer() async throws {
        guard let call, let offer = pendingOffer, let sdp = offer.sdp else { throw CallError.peerConnection }
        ringTimer?.cancel()
        state = .connecting
        statusText = "Connessione"
        configureAudioSession()
        try await makePeerConnection()
        guard let pc else { throw CallError.peerConnection }
        await setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
        let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await pc.setLocalDescription(answer)
        await sendSignal(.callAnswer, to: call.peer) { $0.sdp = answer.sdp }
        if !Self.useCallKit { RTCAudioSession.sharedInstance().isAudioEnabled = true }
        if call.video { cameraOn = true }
    }

    private func answerOrFail() async {
        do { try await performAnswer() } catch { fail(error.localizedDescription) }
    }

    private func performEnd() async {
        let reason = state == .incoming ? "declined" : "hangup"
        Diagnostics.record("chiamata: chiusa da me (\(reason)) stato=\(state)")
        await sendEndIfNeeded(reason: reason)
        teardown(status: reason == "declined" ? "Rifiutata" : "Terminata")
    }

    func flipCamera() {
        frontCamera.toggle()
        if cameraOn { startCapture() }
    }

    // MARK: Segnalazione in arrivo

    private func handleSignal(_ c: Content, from sender: String) async {
        guard let callId = c.callId else { return }
        switch c.kind {
        case .callOffer:
            await incomingOffer(c, from: sender)
        case .callAnswer:
            guard let call, call.callId == callId, call.outgoing, let sdp = c.sdp else { return }
            ringTimer?.cancel()
            state = .connecting
            statusText = "Connessione"
            await setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
        case .callIce:
            guard let call, call.callId == callId, let cand = c.candidate else { return }
            let ice = RTCIceCandidate(sdp: cand, sdpMLineIndex: Int32(c.sdpMLine ?? 0), sdpMid: c.sdpMid)
            if let pc, pc.remoteDescription != nil { try? await pc.add(ice) } else { remoteCandidates.append(ice) }
        case .callEnd:
            guard let call, call.callId == callId else { return }
            let reason: CXCallEndedReason = switch c.reason {
            case "declined": .declinedElsewhere
            case "busy": .unanswered
            case "timeout": .unanswered
            case "failed": .failed
            default: .remoteEnded
            }
            if Self.useCallKit { provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason) }
            endedReasonSent = true
            Diagnostics.record("chiamata: \(sender) ha chiuso (\(c.reason ?? "?")) stato=\(state)")
            teardown(status: c.reason == "busy" ? "Occupato" : c.reason == "declined" ? "Rifiutata" : "Terminata")
        default: break
        }
    }

    private func incomingOffer(_ c: Content, from sender: String) async {
        guard let callId = c.callId, let sdp = c.sdp else { return }
        // Offerta vecchia (coda scaricata dopo ore): la ignoriamo.
        if Date().timeIntervalSince1970 * 1000 - Double(c.ts) > 60_000 { return }
        if state != .idle {
            var end = Content(kind: .callEnd, chat: "dm:\(sender)")
            end.callId = callId; end.reason = "busy"
            try? await MessageService.shared.send(end)
            return
        }
        let placeholder = voipPlaceholder
        voipPlaceholder = nil
        let uuid = placeholder ?? UUID()
        pendingOffer = c
        _ = sdp
        call = ActiveCall(uuid: uuid, callId: callId, peer: sender, video: c.video == true, outgoing: false)
        state = .incoming
        statusText = "Chiamata in arrivo"
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: sender)
        update.localizedCallerName = sender
        update.hasVideo = c.video == true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsDTMF = false
        if !Self.useCallKit {
            // Simulatore: niente CallKit, risponde dalla schermata in-app.
        } else if placeholder != nil {
            provider.reportCall(with: uuid, updated: update)   // la push VoIP l'aveva gia' mostrata come "HESH"
        } else {
            do { try await provider.reportNewIncomingCall(with: uuid, update: update) } catch { Diagnostics.record("chiamata: reportNewIncomingCall: \(error)"); teardown(status: "Chiamata non mostrabile"); return }
        }
        startRingTimer { [weak self] in
            guard let self, let call = self.call, self.state == .incoming else { return }
            if Self.useCallKit { self.provider.reportCall(with: call.uuid, endedAt: Date(), reason: .unanswered) }
            self.teardown(status: "Persa")
        }
    }

    private func startRingTimer(_ onTimeout: @escaping @MainActor () -> Void) {
        ringTimer?.cancel()
        ringTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.ringSeconds * 1_000_000_000)
            if !Task.isCancelled { onTimeout() }
        }
    }

    // MARK: PushKit

    func handleVoIPPush(completion: @escaping () -> Void) {
        // iOS pretende che ogni push VoIP diventi subito una chiamata CallKit. Mostriamo
        // "HESH" e aggiorniamo il nome appena l'offerta cifrata e' stata scaricata e letta.
        let uuid = UUID()
        voipPlaceholder = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "HESH")
        update.localizedCallerName = "HESH"
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] err in
            completion()
            guard err == nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await MessageService.shared.setCallHandler { [weak self] c, from in await self?.handleSignal(c, from: from) }
                _ = try? await MessageService.shared.drainQueue()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.voipPlaceholder == uuid {
                    // Nessuna offerta valida dietro la push: chiudiamo senza suonare oltre.
                    self.voipPlaceholder = nil
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                }
            }
        }
    }

    // MARK: WebRTC

    private func makePeerConnection() async throws {
        let creds = try? await APIClient.shared.turnCredentials()
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.continualGatheringPolicy = .gatherContinually
        cfg.iceServers = creds?.iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
            ?? [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: cfg, constraints: constraints, delegate: self) else { throw CallError.peerConnection }
        self.pc = pc
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audio = factory.audioTrack(with: audioSource, trackId: "audio0")
        audio.isEnabled = !muted
        audioTrack = audio
        pc.add(audio, streamIds: ["hesh"])
        let videoSource = factory.videoSource()
        let video = factory.videoTrack(with: videoSource, trackId: "video0")
        localVideoTrack = video
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        pc.add(video, streamIds: ["hesh"])
        video.isEnabled = false
    }

    private func setRemote(_ desc: RTCSessionDescription) async {
        guard let pc else { return }
        do {
            try await pc.setRemoteDescription(desc)
            for c in remoteCandidates { try? await pc.add(c) }
            remoteCandidates.removeAll()
        } catch { fail("SDP remoto: \(error.localizedDescription)") }
    }

    private func sendSignal(_ kind: Content.Kind, to peer: String, configure: (inout Content) -> Void) async {
        guard let call else { return }
        var c = Content(kind: kind, chat: "dm:\(peer)")
        c.callId = call.callId
        configure(&c)
        do { try await MessageService.shared.send(c) } catch { Diagnostics.record("chiamata: invio \(kind.rawValue) fallito: \(error)") }
    }

    private func setCamera(_ on: Bool) {
        localVideoTrack?.isEnabled = on
        if on { startCapture() } else { capturer?.stopCapture() }
    }

    private func startCapture() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = frontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }) else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min(by: { abs(Int(CMVideoFormatDescriptionGetDimensions($0.formatDescription).width) - 960) < abs(Int(CMVideoFormatDescriptionGetDimensions($1.formatDescription).width) - 960) }) ?? formats[0]
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max().map { min($0, 30) } ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(fps))
    }

    private func setSpeaker(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
        session.unlockForConfiguration()
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, mode: (call?.video == true) ? .videoChat : .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        session.unlockForConfiguration()
    }

    private func fail(_ msg: String) {
        Diagnostics.record("chiamata: \(msg)")
        if let call, Self.useCallKit { provider.reportCall(with: call.uuid, endedAt: Date(), reason: .failed) }
        Task { await sendEndIfNeeded(reason: "failed") }
        teardown(status: "Chiamata fallita")
    }

    private func sendEndIfNeeded(reason: String) async {
        guard !endedReasonSent, let call else { return }
        endedReasonSent = true
        var c = Content(kind: .callEnd, chat: "dm:\(call.peer)")
        c.callId = call.callId
        c.reason = reason
        c.video = call.video
        if let s = call.connectedAt { c.durationS = Date().timeIntervalSince(s) }
        try? await MessageService.shared.send(c)
    }

    private func teardown(status: String) {
        ringTimer?.cancel()
        capturer?.stopCapture()
        pc?.close()
        pc = nil
        audioTrack = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        remoteHasVideo = false
        remoteCandidates.removeAll()
        pendingOffer = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        statusText = status
        state = .ended
        let ended = call
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.call == ended { self.call = nil; self.state = .idle; self.muted = false; self.speaker = false; self.cameraOn = false; self.endedReasonSent = false }
        }
    }

    enum CallError: Error { case peerConnection }
}

// MARK: - CallKit

extension CallService: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in Diagnostics.record("chiamata: providerDidReset"); self.teardown(status: "Reset") }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let call = self.call, call.uuid == action.callUUID else { action.fail(); return }
            do { try await self.performStart(); action.fulfill() } catch { action.fail(); self.fail(error.localizedDescription) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard let call = self.call, call.uuid == action.callUUID else { action.fail(); return }
            do { try await self.performAnswer(); action.fulfill() } catch { action.fail(); self.fail(error.localizedDescription) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            Diagnostics.record("chiamata: CXEndCallAction stato=\(self.state) uuid=\(action.callUUID.uuidString.prefix(8)) mia=\(self.call?.uuid.uuidString.prefix(8) ?? "-")")
            await self.performEnd()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            if self.muted != action.isMuted { self.muted = action.isMuted }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { action.fail() }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
}

// MARK: - PushKit

extension CallService: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { try? await APIClient.shared.setVoIP(token: hex) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        Task { @MainActor in self.handleVoIPPush(completion: completion) }
    }
}

// MARK: - WebRTC delegate

extension CallService: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let call = self.call else { return }
            await self.sendSignal(.callIce, to: call.peer) { $0.candidate = candidate.sdp; $0.sdpMid = candidate.sdpMid; $0.sdpMLine = Int(candidate.sdpMLineIndex) }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            Diagnostics.record("chiamata: ICE \(newState.rawValue) (0 new 1 check 2 conn 3 compl 4 fail 5 disc 6 closed)")
            switch newState {
            case .connected, .completed:
                guard var call = self.call, self.state != .active else { return }
                call.connectedAt = Date()
                self.call = call
                self.state = .active
                self.statusText = ""
                if call.outgoing { self.provider.reportOutgoingCall(with: call.uuid, connectedAt: Date()) }
            case .failed:
                self.fail("ICE fallito (serve il TURN?)")
            case .disconnected:
                self.statusText = "Riconnessione"
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.remoteVideoTrack = track; self.remoteHasVideo = true }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
