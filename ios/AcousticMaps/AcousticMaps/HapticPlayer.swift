import Foundation
import CoreHaptics

@MainActor
final class HapticPlayer {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?

    func play(_ name: String) throws {
        let events: [CHHapticEvent]

        switch name {
        case "tick":
            events = [pulse(at: 0, intensity: 0.8, duration: 0.1)]

        case "turn_left":
            events = [pulse(at: 0, intensity: 1, duration: 0.4)]

        case "turn_right":
            events = [
                pulse(at: 0, intensity: 1, duration: 0.4),
                pulse(at: 0.7, intensity: 1, duration: 0.4)
            ]

        case "off_route":
            events = [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(
                            parameterID: .hapticIntensity,
                            value: 0.9
                        ),
                        CHHapticEventParameter(
                            parameterID: .hapticSharpness,
                            value: 0.3
                        )
                    ],
                    relativeTime: 0,
                    duration: 0.8
                )
            ]

        case "arrived":
            events = [
                pulse(at: 0, intensity: 0.8, duration: 0.3),
                pulse(at: 0.6, intensity: 0.9, duration: 0.3),
                pulse(at: 1.2, intensity: 1, duration: 0.3)
            ]

        default:
            return
        }

        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            throw NSError(
                domain: "AcousticMaps.Haptics",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "This device does not support custom haptics."
                ]
            )
        }

        do {
            if engine == nil {
                let newEngine = try CHHapticEngine()
                newEngine.playsHapticsOnly = true
                newEngine.resetHandler = { [weak self] in
                    Task { @MainActor in
                        self?.player = nil
                        self?.engine = nil
                    }
                }
                engine = newEngine
            }

            guard let engine else { return }
            try engine.start()

            try? player?.stop(atTime: CHHapticTimeImmediate)

            let pattern = try CHHapticPattern(
                events: events,
                parameters: []
            )
            let newPlayer = try engine.makePlayer(with: pattern)
            player = newPlayer
            try newPlayer.start(atTime: CHHapticTimeImmediate)
        } catch {
            player = nil
            engine = nil
            throw error
        }
    }

    // Brief sustained pulses are easier to feel through clothing.
    private func pulse(
        at time: TimeInterval,
        intensity: Float,
        duration: TimeInterval
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: intensity
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: 0.7
                )
            ],
            relativeTime: time,
            duration: duration
        )
    }
}
