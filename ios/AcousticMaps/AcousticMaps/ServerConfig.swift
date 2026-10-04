import Foundation

enum ServerConfig {
    /// Built-in tunnel address. A different one can be typed in Diagnostics (no rebuild needed).
    static let defaultURL = "https://twice-und-legend-bids.trycloudflare.com"
    static let overrideKey = "AcousticMaps.serverURL"

    static var baseURL: String {
        let typed = UserDefaults.standard.string(forKey: overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.hasPrefix("https://") ? typed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : defaultURL
    }
}
