import Foundation
import Combine
import AVFoundation
import CoreLocation

// Keep screen updates on the main thread.
@MainActor
final class ConnectionTest: ObservableObject {
    @Published var instruction = "Where to?"
    @Published private(set) var state = "idle"
    @Published private(set) var lastHaptic: String?
    @Published private(set) var route: [RoutePoint] = []
    @Published private(set) var routeLine: [[Double]] = []
    @Published var destinationName = ""
    @Published private(set) var pastTrips: [PastTrip] = []
    private var tripStartedAt: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: "AcousticMaps.pastTrips"),
           let trips = try? JSONDecoder().decode([PastTrip].self, from: data) {
            pastTrips = trips
        }
    }
    @Published var rawReply = "No reply yet."
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published private(set) var isListening = false
    @Published var hapticError: String?

    private let haptics = HapticPlayer()
    private let speaker = AVSpeechSynthesizer()

    let sessionID = UUID().uuidString

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
        heading: Double?,
        transcript: String? = nil
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
            transcript: transcript
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

            if update.transcript == nil { body["transcript"] = NSNull() }
            if update.heading_deg == nil {
                body["heading_deg"] = NSNull()
            }

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

            guard !Task.isCancelled else { return }
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

            handleReply(reply)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func beginVoiceInput() {
        // Block new speech before stopping the current sentence.
        isListening = true
        speaker.stopSpeaking(at: .immediate)
    }

    func endVoiceInput() {
        isListening = false
    }

    // HTTP responses and voice replies use the same method
    func handleReply(_ reply: ServerReply) {
        let wasOnRoute = ["navigating", "off_route"].contains(state)
        if let points = reply.route { route = points }
        if let line = reply.route_line { routeLine = line }
        if reply.state == "navigating", !wasOnRoute, tripStartedAt == nil {
            tripStartedAt = Date()
        }
        if reply.state == "arrived", let started = tripStartedAt {
            pastTrips.insert(PastTrip(
                id: UUID(), destination: destinationName.isEmpty ? "Walking route" : destinationName,
                date: Date(), duration: Date().timeIntervalSince(started)
            ), at: 0)
            pastTrips = Array(pastTrips.prefix(30))
            if let data = try? JSONEncoder().encode(pastTrips) {
                UserDefaults.standard.set(data, forKey: "AcousticMaps.pastTrips")
            }
            tripStartedAt = nil
        }
        if reply.state == "idle" {
            route = []
            routeLine = []
            tripStartedAt = nil
        }
        if let newState = reply.state { state = newState }
        if let haptic = reply.haptic { lastHaptic = haptic }
        // haptics can arrive without a spoken instruction
        if let name = reply.haptic {
            do {
                try haptics.play(name)
                hapticError = nil
            } catch {
                hapticError = error.localizedDescription
            }
        }

        guard let sentence = reply.say,
              !sentence.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else { return }

        instruction = sentence

        // Don't speak while microphone capture is active.
        guard !isListening else { return }

        do {
            try speak(sentence)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func speak(_ sentence: String) throws {
        // play through the speaker, including with silent mode on
        try AcousticAudioSession.configureAndActivate()

        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: sentence))
    }
}

struct PastTrip: Codable, Identifiable {
    let id: UUID
    let destination: String
    let date: Date
    let duration: TimeInterval
}
