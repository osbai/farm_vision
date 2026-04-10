import Foundation
import Combine
import CoreLocation

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var altitude: Double?
    @Published var gpsAccuracy: Double?
    @Published var speed: Double?
    @Published var course: Double?
    @Published var heading: Double?
    @Published var headingAccuracy: Double?
    @Published var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = kCLHeadingFilterNone
        print("[LocationManager] Requesting location authorization")
        manager.requestWhenInUseAuthorization()
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdates() {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            beginUpdates()
        } else {
            print("[LocationManager] Cannot start updates — not authorized (status: \(status.rawValue))")
        }
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        print("[LocationManager] Stopped location/heading updates")
    }

    private func beginUpdates() {
        print("[LocationManager] Starting location and heading updates")
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        switch status {
        case .authorizedWhenInUse:
            print("[LocationManager] Authorization granted: whenInUse")
            beginUpdates()
        case .authorizedAlways:
            print("[LocationManager] Authorization granted: always")
            beginUpdates()
        case .denied:
            print("[LocationManager] Authorization denied — enable location in Settings")
        case .restricted:
            print("[LocationManager] Authorization restricted by device policy")
        case .notDetermined:
            print("[LocationManager] Authorization not yet determined")
        @unknown default:
            print("[LocationManager] Unknown authorization status: \(status.rawValue)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        latitude = loc.coordinate.latitude
        longitude = loc.coordinate.longitude
        altitude = loc.altitude
        gpsAccuracy = loc.horizontalAccuracy
        speed = loc.speed >= 0 ? loc.speed : nil
        course = loc.course >= 0 ? loc.course : nil
        lastLocation = loc
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.trueHeading >= 0 {
            heading = newHeading.trueHeading
            headingAccuracy = newHeading.headingAccuracy
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] Error: \(error.localizedDescription)")
    }
}
