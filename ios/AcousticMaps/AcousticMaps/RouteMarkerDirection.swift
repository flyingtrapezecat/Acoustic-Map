import MapKit

enum RouteMarkerDirection {
    static func heading(
        at coordinate: CLLocationCoordinate2D,
        along route: [CLLocationCoordinate2D]
    ) -> Double? {
        let point = MKMapPoint(coordinate)
        var nearestDistance = Double.infinity
        var heading: Double?

        // At a turn vertex, prefer the segment leaving it over the one arriving.
        for (start, end) in zip(route, route.dropFirst()) {
            let a = MKMapPoint(start)
            let b = MKMapPoint(end)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { continue }
            let fraction = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            let offsetX = point.x - (a.x + fraction * dx)
            let offsetY = point.y - (a.y + fraction * dy)
            let distance = offsetX * offsetX + offsetY * offsetY
            if distance <= nearestDistance {
                nearestDistance = distance
                heading = atan2(dx, -dy) * 180 / .pi
            }
        }
        return heading
    }
}
