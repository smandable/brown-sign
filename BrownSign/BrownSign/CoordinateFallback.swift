//
//  CoordinateFallback.swift
//  BrownSign
//
//  When Wikidata's P625 (coordinate location) is missing — sparse-stub
//  entries like Drakes Bay Oyster Company (Q17514736) — phase-2
//  enrichment falls back to two extra sources before giving up:
//
//    1. Wikipedia `prop=coordinates`. Some articles tag coords directly
//       in MediaWiki without a corresponding Wikidata claim.
//    2. Regex over the article extract / `rawSummary` (delegated to
//       `parseCoordinatesFromText`). The lead sentence often reads
//       "located at 38°04'57.3"N 122°55'55.0"W". When neither
//       Wikidata nor MediaWiki has structured coords, this rescues
//       the entry so it still gets a map pin.
//
//  Order matters: structured sources first, regex last. A Wikipedia
//  geo claim is authoritative; an inline-text match could in theory
//  hit an off-topic coord (e.g. an article that mentions a different
//  place's location), so it's the fallback of last resort.
//

import Foundation
import CoreLocation

/// Beyond this, the article's own geo claim and the stored (Wikidata
/// P625) coordinate aren't describing the same spot, and the article
/// wins. Below it, the stored value stays — the two sources routinely
/// disagree by a few meters of harmless precision noise.
nonisolated private let coordinateTrustThresholdMeters: Double = 250

/// Resolves coordinates for a phase-2 candidate. Two jobs:
///
/// - `coordinates: nil` from phase-1 → backfill from the fallback
///   chain below. Returns nil when nothing is found; the caller
///   should preserve the original nil.
/// - coordinates present → VERIFY against the article's own geo
///   claim. Wikidata P625 is occasionally wrong by whole streets
///   (the Willard Homestead's pointed at a garden center 770 m up
///   the road, which put the map pin, Directions, and Look Around
///   on the wrong block), while the article's `prop=coordinates` is
///   the curated, building-accurate point. A disagreement beyond
///   `coordinateTrustThresholdMeters` trusts the article.
///
/// Only fires for Wikipedia-sourced candidates — non-Wikipedia sources
/// (NPS) have their own coordinate pipelines and we don't want to risk
/// an irrelevant regex hit against an NPS extract that happens to
/// mention a coord.
nonisolated func backfillCoordinatesIfNeeded(
    for candidate: LandmarkResult
) async -> Coordinate? {
    guard candidate.pageURL.host?.contains("wikipedia.org") == true else {
        return candidate.coordinates
    }

    if let existing = candidate.coordinates {
        return preferArticleCoordinate(
            stored: existing,
            article: await fetchWikipediaCoordinates(forTitle: candidate.title)
        )
    }

    if let fromAPI = await fetchWikipediaCoordinates(forTitle: candidate.title) {
        return fromAPI
    }
    if let parsed = parseCoordinatesFromText(candidate.rawSummary) {
        return Coordinate(latitude: parsed.latitude, longitude: parsed.longitude)
    }
    return nil
}

/// Pure selection between a stored coordinate (usually Wikidata P625)
/// and the article's own geo claim: the article wins when they
/// disagree beyond the trust threshold, the stored value otherwise.
/// Shared by both enrichment paths (Scan phase-2 and the Nearby
/// tap-time `enrichDiscoveredLandmark`).
nonisolated func preferArticleCoordinate(
    stored: Coordinate?,
    article: Coordinate?
) -> Coordinate? {
    guard let stored else { return article }
    guard let article,
          distanceMeters(stored, article) > coordinateTrustThresholdMeters else {
        return stored
    }
    return article
}

nonisolated private func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
}

// MARK: - Wikipedia prop=coordinates

/// Calls MediaWiki's `prop=coordinates` for an article title. Returns
/// the primary geo claim if present, nil otherwise. Many articles tag
/// their coord here even when Wikidata doesn't — this is the cheapest
/// structured fallback.
nonisolated func fetchWikipediaCoordinates(forTitle title: String) async -> Coordinate? {
    // URLComponents-built (apiURL): under the old .urlQueryAllowed
    // interpolation a title containing '&' truncated the query and
    // silently fetched a DIFFERENT article's coordinate — survivable
    // when this was only a nil-coordinate backfill, poisonous now
    // that every enrichment verifies its coordinate through here.
    guard let url = apiURL("https://en.wikipedia.org/w/api.php", [
        URLQueryItem(name: "action", value: "query"),
        URLQueryItem(name: "format", value: "json"),
        URLQueryItem(name: "prop", value: "coordinates"),
        URLQueryItem(name: "redirects", value: "1"),
        URLQueryItem(name: "titles", value: title),
    ]) else {
        return nil
    }
    guard let data = await httpDataWithRetry(apiRequest(url)) else { return nil }

    guard let root = jsonObject(data),
          let queryObj = root["query"] as? [String: Any],
          let pages = queryObj["pages"] as? [String: Any] else {
        return nil
    }
    for (_, rawPage) in pages {
        guard let page = rawPage as? [String: Any],
              let coords = page["coordinates"] as? [[String: Any]],
              let primary = coords.first,
              let lat = primary["lat"] as? Double,
              let lon = primary["lon"] as? Double else {
            continue
        }
        return Coordinate(latitude: lat, longitude: lon)
    }
    return nil
}
