import Foundation
import Combine
import AVFoundation
import CoreLocation

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

        await send(update)
    }

    func sendRealUpdate(
        location: CLLocation,
        heading: Double
    ) async {
        let update = PhoneUpdate(
            session_id: sessionID,
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            accuracy_m: location.horizontalAccuracy,
            heading_deg: heading,
            course_deg: location.course,
            speed_mps: location.speed,
            timestamp: ISO8601DateFormatter().string(
                from: location.timestamp
            ),
            transcript: nil
        )

        await send(update)
    }

    private func send(_ update: PhoneUpdate) async {
        guard !isSending, !Task.isCancelled else { return }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        guard let base = URL(string: ServerConfig.baseURL),
              base.scheme == "https",
              base.host != nil else {
            errorMessage = "The server address must be a valid HTTPS URL."
            return
        }


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
            // switching the trip off cancels its pending request.
            guard !Task.isCancelled else { return }
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
