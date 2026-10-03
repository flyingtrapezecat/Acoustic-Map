import Foundation
import Combine

// Extra fields used by the voice WebSocket.
private struct VoiceMessage: Decodable {
    let type: String?
    let text: String?
    let message: String?
}

@MainActor
final class VoiceStream: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var partialText = ""
    @Published private(set) var status = "Ready to talk."
    @Published private(set) var errorMessage: String?

    // We will connect this to microphone cleanup next.
    var onStop: (() -> Void)?

    private weak var connection: ConnectionTest?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(connection: ConnectionTest) {
        guard !isActive else { return }

        errorMessage = nil
        partialText = ""

        guard var address = URLComponents(
            string: ServerConfig.baseURL
        ), address.scheme == "https", address.host != nil else {
            errorMessage = "Invalid HTTPS server address."
            return
        }

        // Use the same address and session as location updates.
        address.scheme = "wss"
        address.path = "/listen"
        address.queryItems = [
            URLQueryItem(
                name: "session_id",
                value: connection.sessionID
            )
        ]

        guard let url = address.url else {
            errorMessage = "Could not create the voice URL."
            return
        }

        self.connection = connection
        connection.beginVoiceInput()

        isActive = true
        status = "Connecting..."

        let newSocket = URLSession.shared.webSocketTask(with: url)
        socket = newSocket
        newSocket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: newSocket)
        }

        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }

            self?.fail("Voice request timed out. Please try again.")
        }
    }

    // The microphone will call this with converted PCM audio.
    func sendAudio(_ data: Data) async throws {
        guard isActive, let socket else { return }
        try await socket.send(.data(data))
    }

    func stop() {
        // Stop microphone capture before allowing speech again.
        onStop?()

        isActive = false
        receiveTask?.cancel()
        timeoutTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)

        receiveTask = nil
        timeoutTask = nil
        socket = nil

        connection?.endVoiceInput()
        status = "Ready to talk."
    }

    func fail(_ message: String) {
        guard isActive else { return }

        stop()
        errorMessage = message

        // An audible fallback helps when the screen is not visible.
        connection?.handleReply(
            ServerReply(
                say: "Sorry, I didn't catch that. Please try again.",
                haptic: nil,
                state: nil,
                route: nil
            )
        )
    }

    private func receiveMessages(
        from currentSocket: URLSessionWebSocketTask
    ) async {
        do {
            while !Task.isCancelled {
                let frame = try await currentSocket.receive()

                // Ignore messages from an earlier, closed utterance.
                guard socket === currentSocket, isActive else {
                    return
                }

                let data: Data
                switch frame {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let bytes):
                    data = bytes
                @unknown default:
                    continue
                }

                let message = try JSONDecoder().decode(
                    VoiceMessage.self,
                    from: data
                )

                switch message.type {
                case "ready":
                    status = "Listening..."

                case "partial":
                    partialText = message.text ?? partialText

                case "reply":
                    let reply = try JSONDecoder().decode(
                        ServerReply.self,
                        from: data
                    )

                    let raw = String(decoding: data, as: UTF8.self)
                    stop()
                    connection?.rawReply = raw
                    connection?.handleReply(reply)
                    return

                case "error":
                    fail(message.message ?? "Voice server error.")
                    return

                default:
                    continue
                }
            }
        } catch {
            guard !Task.isCancelled,
                  socket === currentSocket else { return }

            fail(error.localizedDescription)
        }
    }
}
