import Foundation
import Combine
import AVFoundation

// keep changes to screen values on main thread
@MainActor
final class ConnectionTest: ObservableObject {
    @Published var instruction = "Ready to test."
    @Published var rawReply = "No reply yet."
    @Published var errorMessage: String?
    @Published var isSending = false

    // keep this object alive for whole app launch
    private let sessionID = UUID().uuidString
    private let speaker = AVSpeechSynthesizer()

    func sendFakeUpdate() async {
        guard !isSending else { return }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        guard let base = URL(string: ServerConfig.baseURL),
              base.scheme == "https",
              base.host != nil else {
            errorMessage = "The server address must be a valid HTTPS URL."
            return
        }

        let update = PhoneUpdate(
            session_id: sessionID,
            lat: 42.448,
            lng: -76.485,
            accuracy_m: 5,
            heading_deg: 90,
            course_deg: 90,
            speed_mps: 1.2,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            transcript: nil
        )

        do {
            let encoded = try JSONEncoder().encode(update)

            var body = try JSONSerialization.jsonObject(with: encoded)
                as? [String: Any] ?? [:]
            body["transcript"] = NSNull()

            var request = URLRequest(
                url: base.appendingPathComponent("update")
            )
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try JSONSerialization.data(
                withJSONObject: body
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )
            rawReply = String(decoding: data, as: UTF8.self)

            guard let http = response as? HTTPURLResponse else {
                errorMessage = "No HTTP response from the server."
                return
            }

            guard (200..<300).contains(http.statusCode) else {
                errorMessage = "Server error: HTTP \(http.statusCode)"
                return
            }

            let reply = try JSONDecoder().decode(
                ServerReply.self,
                from: data
            )

            if let sentence = reply.say,
               !sentence.trimmingCharacters(
                    in: .whitespacesAndNewlines
               ).isEmpty {
                instruction = sentence
                try speak(sentence)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func speak(_ sentence: String) throws {
        let audio = AVAudioSession.sharedInstance()

        // speak even with the silent switch on and lower other audio
        try audio.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try audio.setActive(true)

        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: sentence))
    }
}
