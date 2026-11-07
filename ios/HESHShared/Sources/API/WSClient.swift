import Foundation

/// Stream live delle buste. Riconnessione con backoff; la coda viene comunque
/// svuotata via REST ad ogni avvio, quindi un WS perso non perde messaggi.
public actor WSClient {
    public static let shared = WSClient()

    private var task: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?
    private var backoff: UInt64 = 1
    public private(set) var isConnected = false

    private let decoder = JSONDecoder()
    private var handler: (@Sendable (EnvelopeIn) async -> Void)?

    public func start(onEnvelope: @escaping @Sendable (EnvelopeIn) async -> Void) {
        handler = onEnvelope
        connect()
    }

    public func stop() {
        listener?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
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
        backoff = 1
        listener = Task { [weak self] in
            guard let self else { return }
            await self.listen(t)
        }
    }

    private func listen(_ t: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await t.receive()
                guard case .string(let s) = msg, let data = s.data(using: .utf8) else { continue }
                if let frame = try? decoder.decode(Frame.self, from: data), frame.type == "envelope", let env = frame.envelope {
                    await handler?(env)
                }
            } catch {
                isConnected = false
                let delay = backoff
                backoff = min(backoff * 2, 60)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if !Task.isCancelled { connect() }
                return
            }
        }
    }

    private struct Frame: Decodable {
        var type: String
        var envelope: EnvelopeIn?
    }
}
