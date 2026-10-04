import MapKit

/// Where the walker is along the route line: for the remaining distance, the walked vs
/// remaining parts of the line, and the dotted way back when off route.
struct RouteProgress {
    let alongMeters: Double
    let totalMeters: Double
    let offMeters: Double
    let nearest: CLLocationCoordinate2D
    let segment: Int

    var remainingMeters: Double { max(0, totalMeters - alongMeters) }

    static func locate(_ location: CLLocationCoordinate2D,
                       on line: [CLLocationCoordinate2D]) -> RouteProgress? {
        guard line.count > 1 else { return nil }
        let point = MKMapPoint(location)
        var best: RouteProgress?
        var walked = 0.0
        var total = 0.0
        for (a, b) in zip(line, line.dropFirst()) { total += MKMapPoint(a).distance(to: MKMapPoint(b)) }
        for (index, (a, b)) in zip(line, line.dropFirst()).enumerated() {
            let pa = MKMapPoint(a), pb = MKMapPoint(b)
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0
                ? max(0, min(1, ((point.x - pa.x) * dx + (point.y - pa.y) * dy) / lengthSquared)) : 0
            let snapped = MKMapPoint(x: pa.x + fraction * dx, y: pa.y + fraction * dy)
            let off = point.distance(to: snapped)
            if best == nil || off < best!.offMeters {
                best = RouteProgress(alongMeters: walked + pa.distance(to: snapped), totalMeters: total,
                                     offMeters: off, nearest: snapped.coordinate, segment: index)
            }
            walked += pa.distance(to: pb)
        }
        return best
    }

    /// The line split at the walker: (already walked, still to go).
    func split(_ line: [CLLocationCoordinate2D]) -> ([CLLocationCoordinate2D], [CLLocationCoordinate2D]) {
        let cut = min(segment + 1, line.count)
        return (Array(line[..<cut]) + [nearest], [nearest] + Array(line[cut...]))
    }
}
