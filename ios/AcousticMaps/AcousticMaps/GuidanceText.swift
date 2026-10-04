import Foundation

/// How a spoken sentence is shown on the guidance card: a small label over the text,
/// e.g. "In 40 meters, turn right onto Tower Road." -> ("IN 40 M", "Turn right onto Tower Road.").
enum GuidanceText {
    static func card(sentence: String, state: String) -> (label: String, text: String) {
        if state == "off_route" { return ("OFF ROUTE", sentence) }
        if sentence.hasPrefix("Finding a new route") { return ("NEW ROUTE", sentence) }
        if let match = sentence.firstMatch(of: #/^In (\d+) meters, (.+)$/#) {
            let rest = String(match.2)
            return ("IN \(match.1) M", rest.prefix(1).uppercased() + rest.dropFirst())
        }
        if sentence.hasPrefix("You have arrived") { return ("ARRIVED", sentence) }
        if sentence.hasPrefix("You're back on route") { return ("BACK ON ROUTE", sentence) }
        if sentence.localizedCaseInsensitiveContains(" now") { return ("NOW", sentence) }
        if sentence.hasPrefix("Starting route") { return ("LET'S GO", sentence) }
        return ("ON YOUR WAY", sentence)
    }

    /// The blob's expression for a trip state and the last haptic.
    static func blob(state: String, haptic: String?) -> String {
        switch state {
        case "off_route": return "BlobScared"
        case "arrived": return "BlobHappy"
        case "thinking": return "BlobThinking"
        default: return haptic == "turn_left" ? "BlobPointLeft" : "BlobPointRight"
        }
    }
}
