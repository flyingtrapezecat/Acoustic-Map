import SwiftUI
import MapKit

struct RouteMapView: View {
    let routeLine: [[Double]]
    let turns: [RoutePoint]
    let location: CLLocation?
    @State private var camera: MapCameraPosition = .automatic
    @State private var cameraHeading = 0.0

    private var coordinates: [CLLocationCoordinate2D] {
        routeLine.compactMap { point in
            guard point.count == 2 else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: point[0], longitude: point[1])
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }
    }

    var body: some View {
        Map(position: $camera) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(Color("Action"), lineWidth: 6)
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
                    Circle()
                        .fill(Color("CompassGold"))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color("Ink"), lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
        .onMapCameraChange(frequency: .continuous) { context in
            cameraHeading = context.camera.heading
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                if let location {
                    camera = .camera(MapCamera(centerCoordinate: location.coordinate, distance: 600))
                } else {
                    camera = .automatic
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
        .onChange(of: routeLine) { _, _ in camera = .automatic }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Walking route map with \(turns.count) route points.")
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
