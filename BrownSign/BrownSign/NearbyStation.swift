//
//  NearbyStation.swift
//  BrownSign
//
//  The landmark pool behind the listening features. Play nearby, Narrate
//  as I drive, and the CarPlay Nearby list all draw from it. It fetches
//  around the listener with the Nearby tab's own SPARQL + Wikipedia
//  pipeline, re-fetches as they drive, and decides what to say next: the
//  closest landmark not yet heard, favoring what's ahead of the car over
//  what's already behind it.
//

import Foundation
import CoreLocation
import SwiftData

@MainActor
final class NearbyStation {
    static let shared = NearbyStation()
    /// Posted whenever the pool or its status changes.
    static let didChangeNotification = Notification.Name("NearbyStationDidChange")

    enum Status: Equatable {
        case idle
        case loading
        case loaded
        /// The service answered: nothing within the widest ring.
        case empty
        /// The landmark service couldn't be reached.
        case failed
    }

    /// Car-scale search rings: 10 miles, widening to 25 when fewer than
    /// `sparseThreshold` landmarks turn up (brown-sign country is often rural).
    static let radiusMilesLadder = [10, 25]
    static let sparseThreshold = 5
    /// Rows hydrated per fetch, closest first. The car list shows about
    /// 20, and narration rarely gets further before the listener has moved.
    static let hydrateLimit = 40
    /// Re-fetch once the listener is this far from the last fetch center…
    static let refetchDistance: CLLocationDistance = 3_000
    /// …or the pool is this old.
    static let maxAge: TimeInterval = 30 * 60
    /// After a failed fetch, wait this long before an automatic retry, so
    /// a drive through a dead zone doesn't retry on every location update.
    static let failureBackoff: TimeInterval = 60

    private(set) var status: Status = .idle
    /// Hydrated landmarks from the latest fetch. Unfiltered: hides and the
    /// has-something-to-say check apply at read time, so a landmark hidden
    /// on the phone drops out of the car list right away.
    private(set) var landmarks: [LandmarkResult] = []
    private(set) var center: CLLocationCoordinate2D?
    private(set) var radiusMiles = NearbyStation.radiusMilesLadder[0]

    private var fetchedAt: Date?
    private var lastFailure: Date?
    private var fetchTask: Task<Void, Never>?

    private init() {}

    var radiusMeters: CLLocationDistance { Double(radiusMiles) * 1609.344 }

    private var centerLocation: CLLocation? {
        center.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }

    // MARK: - Fetching

    /// Fetches around `location` unless the pool is fresh and still close
    /// by. `force` fetches regardless (a retry, or the station running dry).
    func refreshIfNeeded(around location: CLLocation, force: Bool = false) async {
        if !force {
            if let fetchTask {
                await fetchTask.value
                return
            }
            if let lastFailure, Date().timeIntervalSince(lastFailure) < Self.failureBackoff {
                return
            }
            if let centerLocation, let fetchedAt, status == .loaded || status == .empty,
               location.distance(from: centerLocation) < Self.refetchDistance,
               Date().timeIntervalSince(fetchedAt) < Self.maxAge {
                return
            }
        }
        fetchTask?.cancel()
        let task = Task { await self.fetch(around: location.coordinate) }
        fetchTask = task
        await task.value
        if fetchTask == task { fetchTask = nil }
    }

    /// Adopts rows the phone's Nearby list already has, so Play nearby on
    /// the phone starts with what's on screen instead of fetching again.
    func seed(_ results: [LandmarkResult], center: CLLocationCoordinate2D, radiusMiles: Int) {
        fetchTask?.cancel()
        fetchTask = nil
        landmarks = results
        self.center = center
        self.radiusMiles = radiusMiles
        fetchedAt = Date()
        lastFailure = nil
        status = results.isEmpty ? .empty : .loaded
        postChange()
    }

    private func fetch(around coordinate: CLLocationCoordinate2D) async {
        if landmarks.isEmpty {
            status = .loading
            postChange()
        }
        let ladder = Self.radiusMilesLadder
        for (index, miles) in ladder.enumerated() {
            let isWidest = index == ladder.count - 1
            var latest: [LandmarkResult] = []
            var latestApplied = false
            var failed = false
            let stream = discoverLandmarksAt(
                center: coordinate,
                radiusMeters: Int(Double(miles) * 1609.344),
                limit: Self.hydrateLimit,
                fastFirstBatch: 15
            )
            for await yield in stream {
                switch yield {
                case .batch(let results, _):
                    latest = results
                    latestApplied = false
                    // First paint: show the closest batch while the rest
                    // hydrate, but only on the first ring (a widening pass
                    // would flash a sparse list and then replace it).
                    if index == 0, results.count >= Self.sparseThreshold, !Task.isCancelled {
                        apply(results, center: coordinate, miles: miles)
                        latestApplied = true
                    }
                case .sparqlFailed:
                    failed = true
                }
            }
            if Task.isCancelled { return }
            if failed {
                lastFailure = Date()
                // Keep an older pool if there is one; a stale list beats none.
                if landmarks.isEmpty || status == .loading { status = .failed }
                postChange()
                return
            }
            if latest.count >= Self.sparseThreshold || isWidest {
                if !latestApplied { apply(latest, center: coordinate, miles: miles) }
                return
            }
        }
    }

    private func apply(_ results: [LandmarkResult], center: CLLocationCoordinate2D, miles: Int) {
        landmarks = results
        self.center = center
        radiusMiles = miles
        fetchedAt = Date()
        lastFailure = nil
        status = results.isEmpty ? .empty : .loaded
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Reading

    /// Landmarks worth offering: not hidden, and with something to say.
    func speakable() -> [LandmarkResult] {
        let hidden = Self.hiddenIDs()
        return landmarks.filter { result in
            !hidden.contains(result.pageURL.absoluteString)
                && !(result.rawSummary.isEmpty && result.summary.isEmpty)
        }
    }

    /// Speakable landmarks nearest first from `location` (or, before a
    /// fix, from the fetch center), with each one's distance.
    func sortedByDistance(from location: CLLocation?) -> [(result: LandmarkResult, meters: CLLocationDistance?)] {
        let reference = location ?? centerLocation
        return speakable()
            .map { result -> (result: LandmarkResult, meters: CLLocationDistance?) in
                guard let reference, let c = result.coordinates else { return (result, nil) }
                return (result, reference.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)))
            }
            .sorted { ($0.meters ?? .infinity) < ($1.meters ?? .infinity) }
    }

    /// Play nearby's next landmark: the closest one not heard this drive
    /// (and, if any are left, not heard in the last month either), with
    /// landmarks already behind a moving car pushed to the back.
    func nextForStation(from location: CLLocation?, excluding heardThisSession: Set<String>) -> LandmarkResult? {
        guard let reference = location ?? centerLocation else { return nil }
        let limit = radiusMeters * 1.5
        let scored: [(result: LandmarkResult, score: Double, id: String)] = speakable().compactMap { result in
            let id = result.pageURL.absoluteString
            guard !heardThisSession.contains(id), let c = result.coordinates else { return nil }
            let meters = reference.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            guard meters <= limit else { return nil }
            if let location, RelativeDirection.of(c, from: location) == .behind {
                return (result, meters * 3, id)
            }
            return (result, meters, id)
        }
        let heard = HeardLandmarks.shared
        if let fresh = scored.filter({ !heard.wasHeardRecently($0.id) }).min(by: { $0.score < $1.score }) {
            return fresh.result
        }
        return scored.min(by: { $0.score < $1.score })?.result
    }

    /// Narrate as I drive's trigger: the closest landmark within earshot
    /// that isn't behind the car and hasn't been heard in the last month.
    /// The ring scales with speed (about 45 seconds of warning), from
    /// 400 m at walking pace up to a mile on the highway.
    func nextApproaching(from location: CLLocation, excluding heardThisSession: Set<String>) -> LandmarkResult? {
        let trigger = min(1_600, max(400, location.speed * 45))
        let heard = HeardLandmarks.shared
        return speakable()
            .compactMap { result -> (result: LandmarkResult, meters: CLLocationDistance)? in
                let id = result.pageURL.absoluteString
                guard !heardThisSession.contains(id), !heard.wasHeardRecently(id),
                      let c = result.coordinates else { return nil }
                let meters = location.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                guard meters <= trigger, RelativeDirection.of(c, from: location) != .behind else { return nil }
                return (result, meters)
            }
            .min { $0.meters < $1.meters }?
            .result
    }

    /// What Play nearby would say next from here, for Up Next.
    func upcoming(from location: CLLocation?, excluding heardThisSession: Set<String>, count: Int) -> [LandmarkResult] {
        var excluded = heardThisSession
        var picks: [LandmarkResult] = []
        while picks.count < count, let next = nextForStation(from: location, excluding: excluded) {
            picks.append(next)
            excluded.insert(next.pageURL.absoluteString)
        }
        return picks
    }

    static func hiddenIDs() -> Set<String> {
        let rows = (try? AppModelContainer.shared.mainContext.fetch(FetchDescriptor<HiddenLandmark>())) ?? []
        return Set(rows.map(\.pageURLString))
    }
}

/// Landmarks narrated recently: page URL → when. Keeps Narrate as I drive
/// from retelling the same landmark on every commute past it, and lets
/// Play nearby lead with ones the listener hasn't heard.
@MainActor
final class HeardLandmarks {
    static let shared = HeardLandmarks()

    /// How long a narrated landmark counts as heard.
    static let window: TimeInterval = 30 * 24 * 3600
    private static let defaultsKey = "listen.heardLandmarks"
    private static let maxEntries = 2_000

    private var entries: [String: Date]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-Self.window)
        entries = stored.compactMapValues { seconds in
            let date = Date(timeIntervalSince1970: seconds)
            return date > cutoff ? date : nil
        }
    }

    func wasHeardRecently(_ id: String) -> Bool {
        guard let date = entries[id] else { return false }
        return Date().timeIntervalSince(date) < Self.window
    }

    func markHeard(_ id: String) {
        entries[id] = Date()
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            for (key, _) in entries.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                entries[key] = nil
            }
        }
        UserDefaults.standard.set(entries.mapValues(\.timeIntervalSince1970), forKey: Self.defaultsKey)
    }
}
