import CoreLocation
import Foundation

/// Best-effort phone coordinates for the set-clock frame's latitude/longitude fields.
///
/// The fields feed the watch's sunrise/sunset face. When location is unavailable or denied the
/// caller sends `0, 0`, which still sets the clock correctly — only that face loses accuracy.
final class PhoneLocation: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var pending: ((CLLocationCoordinate2D?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Returns a recent coordinate, waiting briefly for a fresh fix the first time.
    func currentCoordinate(timeout: TimeInterval = 2.5) async -> CLLocationCoordinate2D? {
        if let cached = manager.location,
           cached.timestamp.timeIntervalSinceNow > -300,
           cached.horizontalAccuracy >= 0 {
            return cached.coordinate
        }

        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return nil
        }

        return await withCheckedContinuation { continuation in
            guard pending == nil else {
                continuation.resume(returning: nil)
                return
            }

            pending = { coordinate in
                continuation.resume(returning: coordinate)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }

            if status == .notDetermined {
                // The prompt's answer arrives in locationManagerDidChangeAuthorization.
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    /// Resumes the pending request exactly once, so a late delegate callback is harmless.
    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        guard let pending else { return }
        self.pending = nil
        pending(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if pending != nil {
                manager.requestLocation()
            }
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }
}
