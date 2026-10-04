import Foundation

/// Server push (`WS /events`): anything the server says outside the once-a-second
/// `/update` rhythm, such as the agent's answer. Each message is handled exactly
/// like an `/update` reply. If the socket drops, nothing is lost: the server sends
/// waiting messages on the next `/update` or when we reconnect.
@MainActor
final class EventStream {
    private var socket: URLSessionWebSocketTask?
    private var task: Task<Void, Never>?

    func start(connection: ConnectionTest) {
        guard task == nil else { return }
        task = Task { [weak self, weak connection] in
            var delay = 1.0
            while !Task.isCancelled {
                guard let self, let connection else { return }
                if await self.listen(connection: connection) { delay = 1 }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 4)   // reconnect after 1 s, 2 s, then every 4 s
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    /// One connection, until it closes. Returns true if any message arrived.
    private func listen(connection: ConnectionTest) async -> Bool {
        guard var address = URLComponents(string: ServerConfig.baseURL) else { return false }
        address.scheme = "wss"
        address.path = "/events"
        address.queryItems = [URLQueryItem(name: "session_id", value: connection.sessionID)]
        guard let url = address.url else { return false }

        let current = URLSession.shared.webSocketTask(with: url)
        socket = current
        current.resume()
        var received = false
        while !Task.isCancelled {
            guard let frame = try? await current.receive() else { break }
            guard case .string(let text) = frame,
                  let data = text.data(using: .utf8),
                  let reply = try? JSONDecoder().decode(ServerReply.self, from: data) else { continue }
            received = true
            connection.handleReply(reply)
        }
        current.cancel(with: .goingAway, reason: nil)
        return received
    }
}
