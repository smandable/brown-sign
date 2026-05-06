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
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class LocationManager: NSObject {
    static let shared = LocationManager()

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var permissionContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    @ObservationIgnored private var inflightFetch: Task<CLLocation?, Never>?

    private(set) var lastLocation: CLLocation?

    /// Published so SwiftUI views can react to the user granting/denying
    /// location permission (e.g. show/hide a "Turn on location" banner).
    /// Updated from `locationManagerDidChangeAuthorization`.
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// True when the user has explicitly denied or restricted location
    /// access, so we can't prompt anymore — the only path to authorize
    /// is through the system Settings app.
    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// True when we have at least When-In-Use authorization.
    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse
            || authorizationStatus == .authorizedAlways
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    /// Deeplink into this app's system Settings page so the user can
    /// flip Location from Never to While Using. iOS also sends us a
    /// fresh `locationManagerDidChangeAuthorization` when they come
    /// back, which unsticks any UI that was gated on `isDenied`.
    #if canImport(UIKit)
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif

    /// Kick off a background `currentLocation()` fetch IF we already
    /// have permission. Used at app launch to pre-warm the GPS so by
    /// the time the user opens the Nearby tab, `lastLocation` is
    /// populated and the SPARQL fetch isn't blocked on a 2–10 s cold
    /// radio fix. No-op when authorization is `.notDetermined` so we
    /// never pop the system permission prompt at launch — the prompt
    /// still appears in-context the first time the user opens Nearby.
    /// `currentLocation()` already dedupes via `inflightFetch`, so a
    /// follow-up call from the view won't double-fetch.
    func warmUpIfAuthorized() {
        guard isAuthorized else { return }
        Task { _ = await currentLocation() }
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
    ///
    /// Pass `bypassCache: true` when the caller is an explicit user
    /// gesture that needs a guaranteed-fresh fix (toolbar refresh,
    /// pull-to-refresh) — drops the 5-min cache so the call falls
    /// through to a real `requestLocation()`. If a fetch is already
    /// in flight we still adopt its result rather than spawning a
    /// parallel one, since `CLLocationManager`'s
    /// `locationContinuation` is single-shot; an in-flight fetch is
    /// by definition a fresh GPS request, not stale cache.
    func currentLocation(withTimeout seconds: TimeInterval, bypassCache: Bool = false) async -> CLLocation? {
        if bypassCache {
            lastLocation = nil
        }
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
        let status = manager.authorizationStatus
        Task { @MainActor in
            // Auth transition (most importantly the off→on Location
            // Services toggle, which routes through .denied) means
            // any cached fix is now untrustworthy — the user may have
            // moved while location was disabled, or GPS will
            // re-acquire at a slightly different spot. Drop the
            // cache so the next fetch actually calls
            // `requestLocation()` instead of short-circuiting on the
            // pre-toggle fix. Don't touch `inflightFetch` — its
            // `CheckedContinuation` must resume exactly once, and the
            // OS will fire `didFailWithError` to do so naturally.
            if self.authorizationStatus != status {
                self.lastLocation = nil
            }
            self.authorizationStatus = status
            let granted: Bool
            switch status {
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
