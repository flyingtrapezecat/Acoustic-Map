import Foundation

import CoreLocation
import Combine

// read sensors and publish their values for the screen
@MainActor
final class LocationReader: NSObject, ObservableObject,
                            CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var headingDegrees: Double?
    @Published var status = "Location has not started."
    
    private var tripActive = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }
    
    func start() {
        tripActive = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            status = "Waiting for location."
            manager.startUpdatingLocation()

            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        case .denied, .restricted:
            status = "Location permission is unavailable."
        @unknown default:
            status = "Unknown location permission."
        }
    }
    
    func stop() {
        tripActive = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        status = "Trip stopped."
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        // only resume after permission if trip is still active
        if tripActive,
           manager.authorizationStatus != .notDetermined {
            start()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard tripActive else { return }

        guard let latest = locations.last,
              latest.horizontalAccuracy >= 0 else { return }

        location = latest
        status = "Receiving location."
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        guard tripActive else { return }

        guard newHeading.headingAccuracy >= 0 else { return }

        headingDegrees = newHeading.trueHeading >= 0
            ? newHeading.trueHeading
            : newHeading.magneticHeading
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        status = error.localizedDescription
    }
}
