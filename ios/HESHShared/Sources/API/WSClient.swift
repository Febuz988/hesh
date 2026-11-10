import Foundation

/// Stream live delle buste. Riconnessione con backoff; la coda viene comunque
/// svuotata via REST ad ogni avvio, quindi un WS perso non perde messaggi.
public actor WSClient {
    public static let shared = WSClient()

    private var task: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var generation = 0
    private var backoff: UInt64 = 1
    public private(set) var isConnected = false

    private let decoder = JSONDecoder()
    private var handler: (@Sendable (EnvelopeIn) async -> Void)?

    public func start(onEnvelope: @escaping @Sendable (EnvelopeIn) async -> Void) {
        handler = onEnvelope
        connect()
    }

    public func stop() {
        generation += 1
        listener?.cancel()
        pinger?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    /// Ritorno in primo piano o cambio rete: chiude e riapre subito, senza backoff.
    public func reconnect() {
        guard handler != nil else { return }
        stop()
        backoff = 1
        connect()
    }

    public func ack(_ ids: [String]) async {
        guard let task, !ids.isEmpty else { return }
        let payload = try? JSONSerialization.data(withJSONObject: ["type": "ack", "ids": ids])
        if let payload, let s = String(data: payload, encoding: .utf8) {
            try? await task.send(.string(s))
        }
    }

    private func connect() {
        guard let token = Keychain.string(for: .sessionToken) else { return }
        var comps = URLComponents(url: HESHConfig.wsBase.appendingPathComponent("messages/stream"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        let t = URLSession.shared.webSocketTask(with: comps.url!)
        task = t
        t.resume()
        isConnected = true
        generation += 1
        let gen = generation
        listener = Task { [weak self] in
            guard let self else { return }
            await self.listen(t, gen: gen)
        }
        // Ping ogni 25 s: senza, un socket morto (NAT scaduto, Mac in stop, cambio rete)
        // resta "connesso" per entrambi e il server non manda nemmeno la push.
        pinger?.cancel()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { return }
                guard let self, await self.generation == gen else { return }
                let ok = await Self.ping(t)
                if !ok { await self.dropAndRetry(gen: gen); return }
            }
        }
    }

    private static func ping(_ t: URLSessionWebSocketTask) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { cont in
            let timeout = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if once.claim() { cont.resume(returning: false) } }
            t.sendPing { err in
                timeout.cancel()
                if once.claim() { cont.resume(returning: err == nil) }
            }
        }
    }

    /// Garantisce una sola resume() della continuation tra callback e timeout.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private func dropAndRetry(gen: Int) async {
        guard generation == gen else { return }
        listener?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        isConnected = false
        backoff = 1
        connect()
    }

    private func listen(_ t: URLSessionWebSocketTask, gen: Int) async {
        while !Task.isCancelled {
            do {
                let msg = try await t.receive()
                guard case .string(let s) = msg, let data = s.data(using: .utf8) else { continue }
                if let frame = try? decoder.decode(Frame.self, from: data), frame.type == "envelope", let env = frame.envelope {
                    await handler?(env)
                }
            } catch {
                guard generation == gen else { return }   // sostituito da reconnect(): esce in silenzio
                isConnected = false
                let delay = backoff
                backoff = min(backoff * 2, 60)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if !Task.isCancelled, generation == gen { connect() }
                return
            }
        }
    }

    private struct Frame: Decodable {
        var type: String
        var envelope: EnvelopeIn?
    }
}
