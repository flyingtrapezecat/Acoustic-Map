import Foundation

// data phone sends to POST/update
struct PhoneUpdate: Codable {
    let session_id: String
    let lat: Double
    let lng: Double
    let accuracy_m: Double
    let heading_deg: Double?
    let course_deg: Double
    let speed_mps: Double
    let timestamp: String
    let transcript: String?
}

// data server sends back
struct ServerReply: Codable {
    let say: String?
    let haptic: String?
    let state: String?
    let route: [RoutePoint]?
    var route_line: [[Double]]? = nil
}

struct RoutePoint: Codable {
    let lat: Double?
    let lng: Double?
    let instruction: String?
    let turn: String?
}
