//
//  NearbyResultsCache.swift
//  BrownSign
//
//  Disk-backed snapshot of the most recent Nearby fetch. Rendered
//  immediately on cold-start so the user sees pins from their last
//  session without waiting for SPARQL + Wikipedia hydration. The fresh
//  fetch runs in the background and replaces the cache when it lands
//  (stale-while-revalidate).
//
//  Stored as one JSON file under `Caches/` — single atomic snapshot,
//  not queryable, and `Caches/` is purgeable under storage pressure
//  which is exactly the right semantic for a regenerable lookup. We
//  don't use SwiftData here because the cache is a single document, not
//  a collection of records — the existing `@Model` types
//  (`HiddenLandmark`, `LandmarkLookup`) are queryable per-row, which
//  isn't what this cache needs.
//
//  Spatial invalidation is the caller's job: `NearMeView` checks that
//  the user's actual GPS fix is within `searchRadiusMeters` of
//  `fetchCenter` before trusting the cached pins. If not, the cache is
//  cleared and a `.loading` state is shown until the fresh fetch lands.
//

import Foundation

/// One Nearby fetch, snapshotted to disk so the next cold-start can
/// render it instantly while a fresh fetch runs in the background.
/// `nonisolated` so the synthesized Codable conformance can be invoked
/// from `save`'s detached Task without crossing the project-default
/// MainActor boundary.
nonisolated struct CachedNearbyFetch: Codable {
    /// Bumped whenever the encoded shape of `LandmarkResult` /
    /// `Coordinate` changes in a way old caches can't be decoded
    /// against. Old caches with a mismatched schema are silently
    /// discarded on load.
    let schemaVersion: Int
    let fetchCenter: Coordinate
    let fetchedAt: Date
    let results: [LandmarkResult]
}

enum NearbyResultsCache {
    /// Bump this when `LandmarkResult` or `Coordinate` change shape in
    /// an incompatible way. Old caches are dropped on load.
    static let currentSchema = 1

    /// Stale-after duration. 7 days is well past most users' typical
    /// re-open cadence and short enough that minor article-image URL
    /// rot or allowlist tweaks between releases don't outlive it.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    nonisolated private static let fileName = "nearby_results_cache.json"

    /// Returns the cached fetch if one exists, has the current schema,
    /// and isn't older than `maxAge`. Returns nil otherwise — and
    /// proactively deletes the file in failure cases (corrupt JSON,
    /// wrong schema, expired) so we don't keep paying the parse cost.
    static func load() -> CachedNearbyFetch? {
        guard let url = cacheFileURL() else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(CachedNearbyFetch.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if cached.schemaVersion != currentSchema {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if Date().timeIntervalSince(cached.fetchedAt) > maxAge {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return cached
    }

    /// Persist the latest fetch. Runs the encode + write off the main
    /// thread; failures are swallowed because the cache is best-effort
    /// (next refresh just rewrites it, and a missing cache only means
    /// the next cold-start pays the full network cost again).
    static func save(_ fetch: CachedNearbyFetch) async {
        await Task.detached(priority: .utility) {
            guard let url = cacheFileURL() else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(fetch) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// Wipe the cache. Used when the user's location turns out to be
    /// far from the cached fetch center — the stale pins are wrong
    /// for where they actually are.
    static func clear() {
        guard let url = cacheFileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `~/Library/Caches/<bundle>/nearby_results_cache.json`. Creates
    /// the parent directory on first use. Returns nil only if the
    /// system Caches directory is somehow unreachable (shouldn't
    /// happen on a normal device). `nonisolated` because `save` reaches
    /// for it from inside a detached Task — a MainActor-bound default
    /// would error under the project's Swift 6 isolation flags.
    nonisolated private static func cacheFileURL() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return base.appendingPathComponent(fileName, isDirectory: false)
    }
}
