//
//  LandmarkResult.swift
//  BrownSign
//
//  The unified landmark result model used across the scan and Nearby
//  tabs. Constructed by the orchestrators in `LandmarkSearch.swift`,
//  which fan out to Wikipedia, NPS, Wikidata, and Apple Intelligence.
//

import Foundation

// `nonisolated` here so the synthesized Codable conformance is itself
// nonisolated. Without this, the project-wide `-default-isolation=MainActor`
// makes `encode(to:)`/`init(from:)` MainActor-isolated, and
// `NearbyResultsCache.save` (which encodes from a detached Task) can't
// call them across the actor boundary in Swift 6 mode.
nonisolated struct Coordinate: Hashable, Codable {
    let latitude: Double
    let longitude: Double
}

nonisolated struct LandmarkResult: Codable {
    let title: String
    /// Polished 2–3 sentence version (via Apple Intelligence if available).
    let summary: String
    /// Original Wikipedia/NPS extract — the full description.
    let rawSummary: String
    let pageURL: URL
    /// "wikipedia" or "nps"
    let source: String
    /// Remote article image URL (Wikipedia pageimages thumbnail).
    let articleImageURL: URL?
    /// Downloaded article image bytes, populated by `enrichLandmark`.
    /// UI should prefer this over `articleImageURL` — `AsyncImage` has
    /// no retry and caches failure states, so we download once and
    /// persist the bytes for reliable display.
    let articleImageData: Data?
    let coordinates: Coordinate?
    let inceptionYear: Int?
    let wikidataType: String?
    /// Apple Intelligence on-device match judgment (0.0–1.0).
    let onDeviceMatchScore: Double?
}

extension LandmarkResult {
    /// A copy of `self` with enrichment gaps filled from `other` — the
    /// same landmark seen by another pass (a fresh Nearby fetch, or
    /// tap-time enrichment). Existing values always win; only fields
    /// `self` lacks adopt `other`'s. This is how a row whose hydration
    /// once missed a field (one bad network moment) heals later,
    /// instead of the gap being preserved by every merge and re-saved
    /// into the Nearby disk cache indefinitely.
    func fillingEnrichmentGaps(from other: LandmarkResult) -> LandmarkResult {
        LandmarkResult(
            title: title,
            summary: summary.isEmpty ? other.summary : summary,
            rawSummary: rawSummary.isEmpty ? other.rawSummary : rawSummary,
            pageURL: pageURL,
            source: source,
            articleImageURL: articleImageURL ?? other.articleImageURL,
            articleImageData: articleImageData ?? other.articleImageData,
            coordinates: coordinates ?? other.coordinates,
            inceptionYear: inceptionYear ?? other.inceptionYear,
            wikidataType: wikidataType ?? other.wikidataType,
            onDeviceMatchScore: onDeviceMatchScore ?? other.onDeviceMatchScore
        )
    }

    /// A copy of `self` without the downloaded image bytes. Nearby's
    /// in-state rows (and therefore its disk cache, which serializes
    /// them verbatim as JSON) should carry the image URL, not base64'd
    /// JPEGs — the bytes already live in SwiftData via upsert.
    var droppingImageBytes: LandmarkResult {
        LandmarkResult(
            title: title,
            summary: summary,
            rawSummary: rawSummary,
            pageURL: pageURL,
            source: source,
            articleImageURL: articleImageURL,
            articleImageData: nil,
            coordinates: coordinates,
            inceptionYear: inceptionYear,
            wikidataType: wikidataType,
            onDeviceMatchScore: onDeviceMatchScore
        )
    }
}
