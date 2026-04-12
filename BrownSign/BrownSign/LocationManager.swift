//
//  LocationManager.swift
//  BrownSign
//
//  Thin async/await wrapper around CLLocationManager. Handles
//  permission prompts and one-shot location fetches. Caches the most
//  recent fix for ~5 minutes so repeated searches don't spam the GPS.
//

import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var inflightFetch: Task<CLLocation?, Never>?

    private(set) var lastLocation: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Request "When In Use" permission if we don't already have it.
    /// Returns true if we're authorized, false otherwise.
    func ensurePermission() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                permissionContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    /// Returns `lastLocation` if available, otherwise waits up to
    /// `seconds` for a fresh fix. Designed to be called from a search
    /// path: you want the best location you can get quickly, but you
    /// don't want to stall forever if the GPS is slow.
    func currentLocation(withTimeout seconds: TimeInterval) async -> CLLocation? {
        if let cached = lastLocation,
           Date().timeIntervalSince(cached.timestamp) < 300 {
            return cached
        }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                await self.currentLocation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Returns the current location if available. Uses a recent cache to
    /// avoid hitting the GPS on every search. Returns nil on denial or
    /// any failure — callers should treat location as optional.
    /// Concurrent calls share a single in-flight fetch so they don't
    /// clobber each other's continuation.
    func currentLocation() async -> CLLocation? {
        if let cached = lastLocation,
           Date().timeIntervalSince(cached.timestamp) < 300 {
            return cached
        }
        if let existing = inflightFetch {
            return await existing.value
        }

        let task = Task<CLLocation?, Never> { [weak self] in
            guard let self else { return nil }
            guard await self.ensurePermission() else { return nil }
            return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
                self.locationContinuation = continuation
                self.manager.requestLocation()
            }
        }
        inflightFetch = task
        let value = await task.value
        inflightFetch = nil
        return value
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let granted: Bool
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                granted = true
            default:
                granted = false
            }
            permissionContinuation?.resume(returning: granted)
            permissionContinuation = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let latest = locations.last
        Task { @MainActor in
            self.lastLocation = latest
            self.locationContinuation?.resume(returning: latest)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.locationContinuation?.resume(returning: nil)
            self.locationContinuation = nil
        }
    }
}
