import SwiftUI
import MapKit

struct RouteMapView: View {
    let routeLine: [[Double]]
    var previousLine: [[Double]] = []
    let turns: [RoutePoint]
    let location: CLLocation?
    var offRoute = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var cameraHeading = 0.0
    // Show the whole route first, then follow the walker (until they pan the map).
    @State private var routeShownAt = Date()
    private let overviewSeconds = 4.0
    private let followDistance = 350.0

    private var coordinates: [CLLocationCoordinate2D] { Self.coordinates(routeLine) }

    private static func coordinates(_ line: [[Double]]) -> [CLLocationCoordinate2D] {
        line.compactMap { point in
            guard point.count == 2 else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: point[0], longitude: point[1])
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
    }

    private var progress: RouteProgress? {
        location.flatMap { RouteProgress.locate($0.coordinate, on: coordinates) }
    }

    private let dotted = StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 8])

    var body: some View {
        Map(position: $camera) {
            let previous = Self.coordinates(previousLine)
            if previous.count > 1 {
                MapPolyline(coordinates: previous)
                    .stroke(Color("SecondaryText").opacity(0.6), style: dotted)
            }
            if coordinates.count > 1 {
                if let progress {
                    let (walked, ahead) = progress.split(coordinates)
                    MapPolyline(coordinates: walked)
                        .stroke(Color("Action").opacity(0.3), lineWidth: 6)
                    MapPolyline(coordinates: ahead)
                        .stroke(Color("Action"), lineWidth: 6)
                    if offRoute, let location {
                        MapPolyline(coordinates: [location.coordinate, progress.nearest])
                            .stroke(Color.red, style: dotted)
                    }
                } else {
                    MapPolyline(coordinates: coordinates)
                        .stroke(Color("Action"), lineWidth: 6)
                }
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                if let lat = turn.lat, let lng = turn.lng,
                   CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
                    Annotation(turn.instruction ?? "Route point", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
                        Image(systemName: symbol(for: turn))
                            .font(.system(size: 12, weight: .bold))
                            .rotationEffect(.degrees(markerRotation(for: turn)))
                            .foregroundStyle(Color("Action"))
                            .frame(width: 28, height: 28)
                            .background(.white, in: Circle())
                            .overlay(Circle().stroke(Color("Action"), lineWidth: 2.5))
                    }
                    .annotationTitles(.hidden)
                }
            }
            if let location {
                Annotation("Your location", coordinate: location.coordinate) {
                    LocationDot()
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
        .onMapCameraChange(frequency: .continuous) { context in
            cameraHeading = context.camera.heading
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.6)) {
                    if let location {
                        camera = .camera(MapCamera(centerCoordinate: location.coordinate,
                                                   distance: followDistance, heading: cameraHeading))
                    } else {
                        camera = .automatic
                    }
                }
            } label: {
                Image(systemName: "location.fill")
                    .frame(width: 44, height: 44)
                    .background(.white, in: Circle())
                    .overlay(Circle().stroke(Color("Ink"), lineWidth: 2.5))
            }
            .accessibilityLabel(location == nil ? "Show entire route" : "Center on your location")
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
        .onChange(of: routeLine) { _, _ in
            routeShownAt = Date()
            withAnimation(.easeInOut(duration: 0.8)) { camera = .automatic }
        }
        .onChange(of: location) { _, fix in follow(fix) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Walking route map with \(turns.count) route points.")
    }

    /// Keep the walker centered, heading-up while moving, unless they've panned the map.
    private func follow(_ fix: CLLocation?) {
        guard let fix, !camera.positionedByUser,
              Date().timeIntervalSince(routeShownAt) > overviewSeconds else { return }
        let heading = fix.speed > 0.5 && fix.course >= 0 ? fix.course : cameraHeading
        withAnimation(.easeInOut(duration: 0.9)) {
            camera = .camera(MapCamera(centerCoordinate: fix.coordinate, distance: followDistance,
                                       heading: heading))
        }
    }

    private func symbol(for turn: RoutePoint) -> String {
        switch turn.turn {
        case "left", "right", "straight", "slight_left", "slight_right",
             "sharp_left", "sharp_right", "uturn":
            return markerHeading(for: turn) == nil ? "circle.fill" : "arrow.up"
        case "arrive": return "flag.fill"
        default: return "circle.fill"
        }
    }

    private func markerHeading(for turn: RoutePoint) -> Double? {
        guard let lat = turn.lat, let lng = turn.lng else { return nil }
        return RouteMarkerDirection.heading(
            at: CLLocationCoordinate2D(latitude: lat, longitude: lng), along: coordinates
        )
    }

    private func markerRotation(for turn: RoutePoint) -> Double {
        guard symbol(for: turn) == "arrow.up",
              let heading = markerHeading(for: turn) else { return 0 }
        return heading - cameraHeading
    }
}

/// The walker's dot, with a soft pulse so it's easy to find on the map.
private struct LocationDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color("CompassGold").opacity(0.35))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 2.2 : 1)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Color("CompassGold"))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color("Ink"), lineWidth: 3))
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
