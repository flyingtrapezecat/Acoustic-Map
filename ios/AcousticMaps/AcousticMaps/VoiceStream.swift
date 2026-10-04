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
    @Published private(set) var isPreparing = false
    @Published private(set) var audioDiagnostics = ""
    /// Smoothed microphone level, 0...1, for the listening animation.
    @Published private(set) var level = 0.0
    private var uploadedFrames = 0
    private var silentFrames = 0
    private var restartedMicrophone = false
    // 1.2 s of exact zeros means a stale input, not a quiet room.
    private let silentFramesLimit = 12
    private var inputPeak = 0.0
    private var pcmPeak = 0.0
    private let microphone = MicrophoneCapture()
    private var uploadTask: Task<Void, Never>?

    // We will connect this to microphone cleanup next.
    var onStop: (() -> Void)?

    private weak var connection: ConnectionTest?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    
    func startListening(connection: ConnectionTest) async {
        guard !isActive, !isPreparing else { return }

        isPreparing = true
        errorMessage = nil
        uploadedFrames = 0
        silentFrames = 0
        restartedMicrophone = false
        inputPeak = 0
        pcmPeak = 0
        level = 0
        audioDiagnostics = "Waiting for microphone audio..."
        defer { isPreparing = false }

        guard await microphone.requestPermission() else {
            errorMessage = "Microphone permission is denied. Enable it in Settings."
            return
        }
        guard !Task.isCancelled else { return }

        // This stops app speech before microphone capture starts.
        start(connection: connection)
        guard isActive else { return }
        // Starting the microphone while speech is still tearing down gave silent audio.
        await connection.waitForSpeechToStop()
        guard isActive, !Task.isCancelled else { return }

        do {
            let audio = try microphone.start { [weak self] raw, pcm in
                guard let self, self.isActive else { return }
                self.inputPeak = max(self.inputPeak, raw)
                self.pcmPeak = max(self.pcmPeak, pcm)
                self.level = self.level * 0.6 + min(1, pcm * 4) * 0.4
                self.updateAudioDiagnostics()
            }

            uploadTask = Task { [weak self] in
                guard let self else { return }
                var pending = Data()

                do {
                    for try await bytes in audio {
                        guard !Task.isCancelled, isActive else { return }
                        pending.append(bytes)

                        // 100 ms of 16 kHz mono PCM16 = 3,200 bytes.
                        while pending.count >= 3_200 {
                            guard !Task.isCancelled, isActive else { return }
                            let frame = Data(pending.prefix(3_200))
                            pending.removeFirst(3_200)
                            try await sendAudio(frame)
                            uploadedFrames += 1
                            updateAudioDiagnostics()
                            try checkForSilence(frame)
                        }
                    }
                } catch {
                    guard !Task.isCancelled, isActive else { return }
                    fail(error.localizedDescription)
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Pure digital silence (every sample 0) means the input is stale: rebuild the
    /// microphone once, and if it's still silent, say so instead of uploading nothing.
    private func checkForSilence(_ frame: Data) throws {
        let silent = frame.allSatisfy { $0 == 0 }
        silentFrames = silent ? silentFrames + 1 : 0
        guard silentFrames >= silentFramesLimit else { return }
        silentFrames = 0
        if restartedMicrophone {
            throw NSError(domain: "AcousticMaps.Microphone", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The microphone isn't picking up any sound. Please try again."
            ])
        }
        restartedMicrophone = true
        audioDiagnostics = "Microphone was silent; restarting it."
        try microphone.restart()
    }

    private func updateAudioDiagnostics() {
        audioDiagnostics = String(
            format: "%@ | Mic peak: %.5f | PCM peak: %.5f | Sent: %d frames | %@",
            microphone.inputRoute, inputPeak, pcmPeak, uploadedFrames, microphone.sessionInfo
        )
    }
    
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

    // microphone will call this with converted PCM audio.
    func sendAudio(_ data: Data) async throws {
        guard isActive, let socket else { return }
        try await socket.send(.data(data))
    }

    func stop() {
        // stop microphone capture before allowing speech again.
        microphone.stop()
        uploadTask?.cancel()
        uploadTask = nil
        
        onStop?()

        isActive = false
        level = 0
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

        // audible fallback helps when the screen is not visible.
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
