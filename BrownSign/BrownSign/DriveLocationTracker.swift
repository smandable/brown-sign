//
//  DriveLocationTracker.swift
//  BrownSign
//
//  Continuous location for the listening features, separate from
//  LocationManager's one-shot fixes. It runs only while something needs
//  it: the CarPlay Nearby list on screen, or narration (Play nearby or
//  Narrate as I drive) in progress. Narration keeps it running in the
//  background, so "nearby" stays true while Maps is in front; iOS shows
//  the blue location indicator for exactly as long as that lasts.
//

import CoreLocation

@MainActor
final class DriveLocationTracker: NSObject {
    static let shared = DriveLocationTracker()
    /// Posted when location permission changes (say, granted on the phone
    /// while the car screen shows "Location is off").
    static let authorizationDidChangeNotification = Notification.Name("DriveLocationTrackerAuthorizationDidChange")

    enum Client: Hashable {
        /// The CarPlay Nearby list is on screen (foreground only).
        case carPlayList
        /// Play nearby / Narrate as I drive (continues in the background).
        case narration
    }

    /// The latest fix from continuous updates.
    private(set) var location: CLLocation?

    private let manager = CLLocationManager()
    private var clients: Set<Client> = []
    private var observers: [UUID: (CLLocation) -> Void] = [:]

    private override init() {
        super.init()
        manager.delegate = self
        // GPS-grade accuracy: the course and speed that make "on your left"
        // possible only come from GPS, not Wi-Fi or cell positioning.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 50
        manager.activityType = .automotiveNavigation
        // A red light shouldn't end a drive's updates for good: paused
        // updates never restart on their own while the app is backgrounded.
        manager.pausesLocationUpdatesAutomatically = false
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /// Best recent position: this tracker's fix, else the one-shot
    /// LocationManager's cache, else whatever the system last saw; each
    /// only when it's under five minutes old (LocationManager's trust window).
    var freshestLocation: CLLocation? {
        let candidates = [location, LocationManager.shared.lastLocation, manager.location].compactMap { $0 }
        return candidates
            .filter { Date().timeIntervalSince($0.timestamp) < 300 }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Waits up to `timeout` for a fix under `maxAge` seconds old. False
    /// means updates aren't flowing: iOS won't start them for a When In Use
    /// app that was launched in the background (by Siri, say).
    func waitForFreshFix(maxAge: TimeInterval = 20, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let location, Date().timeIntervalSince(location.timestamp) < maxAge { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    func start(for client: Client) {
        clients.insert(client)
        reconfigure()
    }

    func stop(for client: Client) {
        clients.remove(client)
        reconfigure()
    }

    @discardableResult
    func addObserver(_ handler: @escaping (CLLocation) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func reconfigure() {
        guard isAuthorized, !clients.isEmpty else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            return
        }
        let background = clients.contains(.narration)
        // Requires the `location` UIBackgroundModes entry (Info.plist).
        manager.allowsBackgroundLocationUpdates = background
        manager.showsBackgroundLocationIndicator = background
        manager.startUpdatingLocation()
    }
}

extension DriveLocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.location = latest
            for handler in self.observers.values {
                handler(latest)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.reconfigure()
            NotificationCenter.default.post(name: Self.authorizationDidChangeNotification, object: self)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (kCLErrorLocationUnknown) failures resolve on their own
        // with the next fix; a denial arrives via the authorization callback.
    }
}
