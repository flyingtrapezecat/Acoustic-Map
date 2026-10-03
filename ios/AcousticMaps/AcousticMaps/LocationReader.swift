import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
final class LocationReader: NSObject, ObservableObject,
                            CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var headingDegrees: Double?
    @Published var status = "Location has not started."

    var onUpdate: ((CLLocation, Double) async -> Void)?

    private let manager = CLLocationManager()
    private var tripActive = false
    private var sendTask: Task<Void, Never>?
    private var lastSentAt = Date.distantPast

    override init() {
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        tripActive = true

        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Waiting for location permission."
            manager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse, .authorizedAlways:
            let modes = Bundle.main.object(
                forInfoDictionaryKey: "UIBackgroundModes"
            ) as? [String] ?? []

            guard modes.contains("location") else {
                status = "Enable Location updates in Background Modes."
                return
            }

            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()

            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }

            status = "Waiting for location."

        case .denied, .restricted:
            stop()
            status = "Location permission is unavailable."

        @unknown default:
            stop()
            status = "Unknown location permission."
        }
    }

    func stop() {
        tripActive = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        sendTask?.cancel()
        lastSentAt = .distantPast
        status = "Trip stopped."
    }

    func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        guard tripActive,
              manager.authorizationStatus != .notDetermined else {
            return
        }

        start()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard tripActive,
              let latest = locations.last,
              latest.horizontalAccuracy >= 0 else {
            return
        }

        location = latest
        status = "Receiving location."
        sendIfReady(latest)
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateHeading newHeading: CLHeading
    ) {
        guard tripActive,
              newHeading.headingAccuracy >= 0 else {
            return
        }

        headingDegrees = newHeading.trueHeading >= 0
            ? newHeading.trueHeading
            : newHeading.magneticHeading
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard tripActive else { return }
        status = error.localizedDescription
    }

    private func sendIfReady(_ fix: CLLocation) {
        guard tripActive,
              sendTask == nil,
              let heading = headingDegrees,
              let onUpdate,
              Date().timeIntervalSince(lastSentAt) >= 1 else {
            return
        }

        lastSentAt = Date()

        // Give an in-flight request time to finish in the background.
        let backgroundID = UIApplication.shared.beginBackgroundTask(
            withName: "Send location update"
        ) { [weak self] in
            Task { @MainActor in
                self?.sendTask?.cancel()
            }
        }

        sendTask = Task { [self] in
            defer {
                if backgroundID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundID)
                }

                sendTask = nil
            }

            guard tripActive, !Task.isCancelled else { return }
            await onUpdate(fix, heading)
        }
    }
}
