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

/// Resolves coordinates for a phase-2 candidate that came back from
/// phase-1 with `coordinates: nil`. Returns nil when none of the
/// fallbacks find anything; the caller should preserve the original
/// nil in that case.
///
/// Only fires for Wikipedia-sourced candidates — non-Wikipedia sources
/// (NPS) have their own coordinate pipelines and we don't want to risk
/// an irrelevant regex hit against an NPS extract that happens to
/// mention a coord.
func backfillCoordinatesIfNeeded(
    for candidate: LandmarkResult
) async -> Coordinate? {
    if let existing = candidate.coordinates { return existing }
    guard candidate.pageURL.host?.contains("wikipedia.org") == true else {
        return nil
    }

    if let fromAPI = await fetchWikipediaCoordinates(forTitle: candidate.title) {
        return fromAPI
    }
    if let parsed = parseCoordinatesFromText(candidate.rawSummary) {
        return Coordinate(latitude: parsed.latitude, longitude: parsed.longitude)
    }
    return nil
}

// MARK: - Wikipedia prop=coordinates

/// Calls MediaWiki's `prop=coordinates` for an article title. Returns
/// the primary geo claim if present, nil otherwise. Many articles tag
/// their coord here even when Wikidata doesn't — this is the cheapest
/// structured fallback.
func fetchWikipediaCoordinates(forTitle title: String) async -> Coordinate? {
    guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&prop=coordinates&redirects=1&titles=\(encoded)") else {
        return nil
    }
    guard let data = await httpDataWithRetry(URLRequest(url: url)) else { return nil }

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
