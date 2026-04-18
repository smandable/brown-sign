//
//  LandmarkResult.swift
//  BrownSign
//
//  The unified landmark result plus the top-level orchestrator that
//  fans out to Wikipedia, NPS, Wikidata, Google Knowledge Graph, and
//  Apple Intelligence.
//

import Foundation
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

struct Coordinate: Hashable {
    let latitude: Double
    let longitude: Double
}

struct LandmarkResult {
    let title: String
    /// Polished 2–3 sentence version (via Apple Intelligence if available).
    let summary: String
    /// Original Wikipedia/NPS extract — the full description.
    let rawSummary: String
    let pageURL: URL
    /// "wikipedia", "nps", or "osm"
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
    /// Google Knowledge Graph resultScore (relative, not bounded 0–1).
    let externalConfidence: Double?
    /// Apple Intelligence on-device match judgment (0.0–1.0).
    let onDeviceMatchScore: Double?

    static func from(wiki: WikiResult) -> LandmarkResult {
        LandmarkResult(
            title: wiki.title,
            summary: wiki.summary,
            rawSummary: wiki.summary,
            pageURL: wiki.pageURL,
            source: "wikipedia",
            articleImageURL: wiki.imageURL,
            articleImageData: nil,
            coordinates: nil,
            inceptionYear: nil,
            wikidataType: nil,
            externalConfidence: nil,
            onDeviceMatchScore: nil
        )
    }

    static func from(nps: NPSResult) -> LandmarkResult {
        LandmarkResult(
            title: nps.title,
            summary: nps.summary,
            rawSummary: nps.summary,
            pageURL: nps.pageURL,
            source: "nps",
            articleImageURL: nps.imageURL,
            articleImageData: nil,
            coordinates: nil,
            inceptionYear: nil,
            wikidataType: nil,
            externalConfidence: nil,
            onDeviceMatchScore: nil
        )
    }

    static func from(osm: OSMResult) -> LandmarkResult {
        LandmarkResult(
            title: osm.title,
            summary: osm.summary,
            rawSummary: osm.summary,
            pageURL: osm.pageURL,
            source: "osm",
            articleImageURL: osm.imageURL,
            articleImageData: nil,
            coordinates: Coordinate(
                latitude: osm.latitude,
                longitude: osm.longitude
            ),
            inceptionYear: nil,
            wikidataType: nil,
            externalConfidence: nil,
            onDeviceMatchScore: nil
        )
    }
}

/// Phase-1 candidate search. Returns all plausible landmarks as
/// lightweight `LandmarkResult` values (basic info + Wikidata enrichment,
/// but no polish/Google KG/match score). Sorted nearby-first when a user
/// location is available, otherwise text-rank order.
///
/// The slower phase-2 work (summary polish, Google KG, on-device match
/// judgment) runs per-candidate only when the user actually selects one,
/// via `enrichLandmark(_:query:)`.
func searchLandmarkCandidates(
    query: String,
    userLocation: CLLocation? = nil
) async -> [LandmarkResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    // Kick off OSM in parallel with the Wikipedia searches — Overpass
    // can be slower than Wikipedia (up to ~20 s on a cold query), so
    // starting it first lets it finish in the background while we're
    // building the Wikipedia candidate list. If there's no user
    // location, OSM is skipped entirely (Overpass is geographic-only).
    async let osmCandidatesTask: [OSMResult] = {
        guard let user = userLocation else { return [] }
        return await searchOpenStreetMapNearby(
            query: trimmed,
            latitude: user.coordinate.latitude,
            longitude: user.coordinate.longitude,
            radiusMeters: 10_000
        )
    }()

    // 1a. Geographic Wikipedia search within 10 km of the user (if
    //     known). 10 km is Wikipedia's API-enforced maximum for
    //     geosearch; larger radii get rejected.
    var nearbyCandidates: [WikiResult] = []
    if let user = userLocation {
        nearbyCandidates = await searchWikipediaNearby(
            query: trimmed,
            latitude: user.coordinate.latitude,
            longitude: user.coordinate.longitude,
            radiusMeters: 10_000
        )
    }

    // 1b. Text-ranked candidates.
    let textCandidates = await searchWikipediaCandidates(query: trimmed)

    // 1c. Merge — geosearch hits first, then text hits (deduped by title).
    var wikiCandidates: [WikiResult] = nearbyCandidates
    let seen = Set(nearbyCandidates.map { $0.title })
    for candidate in textCandidates where !seen.contains(candidate.title) {
        wikiCandidates.append(candidate)
    }

    // 2. Fan out Wikidata lookups in parallel, preserving merge order.
    struct Enriched {
        let index: Int
        let wiki: WikiResult
        let wd: WikidataEnrichment?
    }
    var enriched: [Enriched] = await withTaskGroup(of: Enriched.self) { group in
        for (idx, candidate) in wikiCandidates.enumerated() {
            group.addTask {
                let wd = await fetchWikidataEnrichment(for: candidate.title)
                return Enriched(index: idx, wiki: candidate, wd: wd)
            }
        }
        var results: [Enriched] = []
        for await item in group { results.append(item) }
        results.sort { $0.index < $1.index }
        return results
    }

    // 3. Drop non-landmark types.
    enriched.removeAll { pair in
        if let label = pair.wd?.typeLabel {
            // Wikidata gave us a type — check it.
            return !isLandmarkType(label)
        }
        // No Wikidata type (entity missing or P31 empty). Only keep
        // the article if its title contains a place-indicating word
        // like "fort", "mansion", "park", "bridge", etc. This rejects
        // food items, cultural events, and other non-place articles
        // that Wikipedia's text search returns but that have no
        // Wikidata entity for us to type-check.
        return !titleContainsPlaceWord(pair.wiki.title)
    }

    // 3b. Drop candidates whose title doesn't share significant tokens
    //     with the query. Wikipedia's text search matches article
    //     bodies too, so e.g. "East Haven, CT" will come back for a
    //     "fort Nathan Hale" query because that town's article
    //     mentions the fort. Without this filter, those irrelevant
    //     matches can outrank the real landmark on distance.
    enriched.removeAll { pair in
        !titleMatchesQuery(query: trimmed, title: pair.wiki.title)
    }

    // 4. Assemble [LandmarkResult]. Sort by distance from user when
    //    possible; candidates with no coordinates go to the end,
    //    preserving text-merge order among themselves.
    var built: [(result: LandmarkResult, distance: CLLocationDistance?)] = enriched.map { pair in
        let result = LandmarkResult(
            title: pair.wiki.title,
            summary: pair.wiki.summary,         // unpolished — phase 2 fills this in
            rawSummary: pair.wiki.summary,
            pageURL: pair.wiki.pageURL,
            source: "wikipedia",
            articleImageURL: pair.wiki.imageURL,
            articleImageData: nil,              // downloaded in phase 2
            coordinates: pair.wd?.coordinate,
            inceptionYear: pair.wd?.inceptionYear,
            wikidataType: pair.wd?.typeLabel,
            externalConfidence: nil,
            onDeviceMatchScore: nil
        )
        var distance: CLLocationDistance?
        if let user = userLocation, let coord = pair.wd?.coordinate {
            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            distance = user.distance(from: loc)
        }
        return (result, distance)
    }

    // Sort: exact/close title matches first, then by distance.
    let queryLower = trimmed.lowercased()
    built.sort { a, b in
        let aExact = isCloseTitleMatch(a.result.title, query: queryLower)
        let bExact = isCloseTitleMatch(b.result.title, query: queryLower)
        if aExact != bExact { return aExact }
        switch (a.distance, b.distance) {
        case let (x?, y?): return x < y
        case (_?, nil):    return true
        case (nil, _?):    return false
        case (nil, nil):   return false
        }
    }

    var results = built.map { $0.result }

    // 4b. Augment with OSM nearby results. OSM catches small parks,
    //     monuments, memorials, and historic markers Wikipedia misses.
    //     Dedup by normalized title so OSM doesn't duplicate a
    //     Wikipedia hit for the same feature. Apply the same
    //     title-match filter so OSM's raw name index can't surface
    //     something unrelated to the query.
    let osmCandidates = await osmCandidatesTask
    if !osmCandidates.isEmpty {
        let existingTitles = Set(results.map { $0.title.lowercased() })
        for osm in osmCandidates {
            let key = osm.title.lowercased()
            if existingTitles.contains(key) { continue }
            if !titleMatchesQuery(query: trimmed, title: osm.title) { continue }
            results.append(LandmarkResult.from(osm: osm))
        }
    }

    // 5. NPS fallback only if we got zero Wikipedia candidates.
    //    Apply the same title-match filter so NPS's fuzzy search
    //    doesn't return something completely unrelated (e.g.
    //    "Battleship Bunker" for a "taco" query).
    if results.isEmpty, let nps = await searchNPS(query: trimmed),
       titleMatchesQuery(query: trimmed, title: nps.title) {
        let wd = await fetchWikidataEnrichment(for: nps.title)
        let npsResult = LandmarkResult(
            title: nps.title,
            summary: nps.summary,
            rawSummary: nps.summary,
            pageURL: nps.pageURL,
            source: "nps",
            articleImageURL: nps.imageURL,
            articleImageData: nil,
            coordinates: wd?.coordinate,
            inceptionYear: wd?.inceptionYear,
            wikidataType: wd?.typeLabel,
            externalConfidence: nil,
            onDeviceMatchScore: nil
        )
        results.append(npsResult)
    }

    return results
}

/// Wikipedia-only discovery for the Nearby tab. Fast path —
/// typically returns in well under 2 s. Callers paint this first,
/// then augment with `discoverOSMLandmarksNearby` in a second phase
/// so a slow Overpass query doesn't block the initial list paint.
///
/// Rationale for `titleContainsPlaceWord` rather than Wikidata
/// enrichment: a dense city can have 50+ geo-tagged Wikipedia
/// articles, and fanning out one Wikidata fetch per candidate up
/// front would be slow and wasteful when the user only taps a few.
/// Per-entity Wikidata enrichment runs at tap time via
/// `enrichDiscoveredLandmark`.
func discoverWikipediaLandmarksNearby(
    userLocation: CLLocation,
    radiusMeters: Int = 10_000,
    limit: Int = 40
) async -> [LandmarkResult] {
    let candidates = await wikipediaNearbyCandidates(
        latitude: userLocation.coordinate.latitude,
        longitude: userLocation.coordinate.longitude,
        radiusMeters: radiusMeters,
        limit: limit
    )

    var seenTitles = Set<String>()
    var results: [LandmarkResult] = []
    for c in candidates where titleContainsPlaceWord(c.title) {
        let key = c.title.lowercased()
        if seenTitles.contains(key) { continue }
        seenTitles.insert(key)
        results.append(LandmarkResult(
            title: c.title,
            summary: c.summary,
            rawSummary: c.summary,
            pageURL: c.pageURL,
            source: "wikipedia",
            articleImageURL: c.imageURL,
            articleImageData: nil,
            coordinates: Coordinate(latitude: c.latitude, longitude: c.longitude),
            inceptionYear: nil,
            wikidataType: nil,
            externalConfidence: nil,
            onDeviceMatchScore: nil
        ))
    }

    return Array(results
        .sorted { distanceToUser(userLocation, $0.coordinates) < distanceToUser(userLocation, $1.coordinates) }
        .prefix(limit))
}

/// OpenStreetMap-only discovery for the Nearby tab. Slow path —
/// Overpass can be 5–20 s under load. Call in parallel with
/// `discoverWikipediaLandmarksNearby` so it doesn't block the initial
/// paint, then merge via `mergeNearbyResults` when it returns.
///
/// Skips OSM elements with a `wikipedia` tag. The OSM node for a
/// wiki-tagged feature often sits at a kiosk, sign, or marker near
/// the user while the real article's coordinates are elsewhere (a
/// state-park visitor marker vs. the park itself 50 km away).
/// Letting those through means the distance label is wildly wrong
/// and tapping through would yank the user to a completely different
/// coordinate than the list showed. Wiki-tagged features are supposed
/// to come through the Wikipedia path, and if Wikipedia's own
/// geosearch didn't return them they're out of range.
///
/// OSM elements with no `wikipedia` tag are the genuinely new value —
/// small parks, monuments, memorials, viewpoints Wikipedia doesn't
/// index. Those surface as-is with OSM's coords.
func discoverOSMLandmarksNearby(
    userLocation: CLLocation,
    radiusMeters: Int = 10_000,
    limit: Int = 40
) async -> [LandmarkResult] {
    let candidates = await openStreetMapNearbyCandidates(
        latitude: userLocation.coordinate.latitude,
        longitude: userLocation.coordinate.longitude,
        radiusMeters: radiusMeters,
        limit: limit
    )

    var results: [LandmarkResult] = []
    for osm in candidates where osm.wikipediaTitle == nil {
        results.append(LandmarkResult.from(osm: osm))
    }

    return Array(results
        .sorted { distanceToUser(userLocation, $0.coordinates) < distanceToUser(userLocation, $1.coordinates) }
        .prefix(limit))
}

/// Merges a Wikipedia list with an OSM list, dropping duplicates by
/// (a) lowercase title or (b) coordinate proximity to an existing
/// Wikipedia entry. Wikipedia wins — better content, more reliable
/// coords — so OSM's version of the same feature is dropped.
/// Re-sorts the union by distance from the user and caps at `limit`.
///
/// Coordinate-proximity dedup matters because OSM mappers don't
/// always tag the corresponding `wikipedia=en:…` reference, so a
/// feature that's on Wikipedia still slips through the wiki-tag
/// filter in `discoverOSMLandmarksNearby`. Checking whether the OSM
/// item sits within ~250 m of any Wikipedia item catches those:
/// small parks, monuments, churches where Wikipedia's and OSM's
/// names differ slightly ("Center Church on the Green" vs. "First
/// Church of Christ, New Haven", etc.).
///
/// Pure synchronous function so the caller can swap one list for a
/// fresh copy and re-render without another round trip.
func mergeNearbyResults(
    wikipedia: [LandmarkResult],
    osm: [LandmarkResult],
    userLocation: CLLocation,
    limit: Int
) -> [LandmarkResult] {
    var seenTitles = Set<String>()
    var wikiCoords: [CLLocation] = []
    var merged: [LandmarkResult] = []

    for result in wikipedia {
        let key = result.title.lowercased()
        if seenTitles.contains(key) { continue }
        seenTitles.insert(key)
        merged.append(result)
        if let c = result.coordinates {
            wikiCoords.append(CLLocation(latitude: c.latitude, longitude: c.longitude))
        }
    }

    for result in osm {
        let key = result.title.lowercased()
        if seenTitles.contains(key) { continue }
        // Coordinate-proximity dedup: if any Wikipedia entry sits
        // within 250 m of this OSM entry, treat them as the same
        // real-world feature and prefer Wikipedia's copy.
        if let c = result.coordinates {
            let osmLoc = CLLocation(latitude: c.latitude, longitude: c.longitude)
            if wikiCoords.contains(where: { $0.distance(from: osmLoc) < 250 }) {
                continue
            }
        }
        seenTitles.insert(key)
        merged.append(result)
    }
    merged.sort { distanceToUser(userLocation, $0.coordinates) < distanceToUser(userLocation, $1.coordinates) }
    return Array(merged.prefix(limit))
}

/// Distance helper: .infinity for coordinate-less entries so they
/// sink to the bottom of a distance-sorted list.
private func distanceToUser(
    _ user: CLLocation,
    _ coord: Coordinate?
) -> CLLocationDistance {
    guard let coord else { return .infinity }
    return user.distance(from: CLLocation(
        latitude: coord.latitude,
        longitude: coord.longitude
    ))
}

/// Full enrichment for a candidate tapped from the Nearby tab. Runs the
/// Wikidata lookup in parallel with phase-2 (polish / KG / match score /
/// image download) so the detail view has the same chips as a scan
/// result (type, inception year).
func enrichDiscoveredLandmark(
    _ candidate: LandmarkResult,
    query: String
) async -> LandmarkResult {
    async let wikidata  = fetchWikidataEnrichment(for: candidate.title)
    async let kgScore   = fetchGoogleKGConfidence(for: candidate.title)
    async let polished  = polishSummary(candidate.rawSummary)
    async let matchScore = judgeMatch(
        query: query,
        candidateTitle: candidate.title,
        candidateSummary: candidate.rawSummary
    )
    async let imageTask = downloadArticleImageWithFallback(candidate: candidate)

    let wd      = await wikidata
    let kg      = await kgScore
    let polish  = await polished
    let match   = await matchScore
    let imagePair = await imageTask

    // Prefer Wikidata coords if available, else fall back to the
    // geosearch coords we already had.
    let coord = wd?.coordinate ?? candidate.coordinates

    return LandmarkResult(
        title: candidate.title,
        summary: polish,
        rawSummary: candidate.rawSummary,
        pageURL: candidate.pageURL,
        source: candidate.source,
        articleImageURL: imagePair.url,
        articleImageData: imagePair.data,
        coordinates: coord,
        inceptionYear: wd?.inceptionYear,
        wikidataType: wd?.typeLabel,
        externalConfidence: kg,
        onDeviceMatchScore: match
    )
}

/// Phase-2 enrichment. Takes a basic candidate and runs the slower
/// per-candidate work in parallel: Apple Intelligence summary polish,
/// Google Knowledge Graph confidence, on-device match judgment, AND
/// downloading + resizing the article image bytes so we never have to
/// rely on AsyncImage's unreliable network fetch at display time.
/// Always succeeds (all underlying calls fall back gracefully).
func enrichLandmark(
    _ candidate: LandmarkResult,
    query: String
) async -> LandmarkResult {
    async let kgScore    = fetchGoogleKGConfidence(for: candidate.title)
    async let polished   = polishSummary(candidate.rawSummary)
    async let matchScore = judgeMatch(
        query: query,
        candidateTitle: candidate.title,
        candidateSummary: candidate.rawSummary
    )
    async let imageTask  = downloadArticleImageWithFallback(candidate: candidate)

    let kg      = await kgScore
    let polish  = await polished
    let match   = await matchScore
    let imagePair = await imageTask

    return LandmarkResult(
        title: candidate.title,
        summary: polish,
        rawSummary: candidate.rawSummary,
        pageURL: candidate.pageURL,
        source: candidate.source,
        articleImageURL: imagePair.url,
        articleImageData: imagePair.data,
        coordinates: candidate.coordinates,
        inceptionYear: candidate.inceptionYear,
        wikidataType: candidate.wikidataType,
        externalConfidence: kg,
        onDeviceMatchScore: match
    )
}

/// Fetches the article image at the given URL and resizes it to a
/// reasonable storage size (~800px on its longest edge) before
/// returning the JPEG-encoded bytes. Returns nil on any failure so the
/// caller can fall through to a placeholder. Uses `URLSession.shared`.
private func downloadArticleImage(from url: URL?, title: String) async -> Data? {
    guard let url else { return nil }
    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        // Resize down if the source image is huge, otherwise keep as-is.
        return resizeImageDataIfNeeded(data, maxDimension: 800)
    } catch {
        return nil
    }
}

/// Resolves a candidate's article image URL, falling back to the
/// Wikipedia REST summary endpoint when the legacy `prop=pageimages`
/// candidate URL is nil. See `wikipediaRESTSummaryImageURL` for why
/// the fallback exists. Only attempts REST for Wikipedia-hosted pages;
/// NPS and other sources return their own image URL directly.
/// Returns both the resolved URL (so callers can persist it alongside
/// the downloaded bytes) and the resized JPEG data.
private func downloadArticleImageWithFallback(
    candidate: LandmarkResult
) async -> (url: URL?, data: Data?) {
    var resolved = candidate.articleImageURL
    if resolved == nil,
       candidate.pageURL.host?.contains("wikipedia.org") == true {
        resolved = await wikipediaRESTSummaryImageURL(for: candidate.title)
    }
    let data = await downloadArticleImage(from: resolved, title: candidate.title)
    return (resolved, data)
}

/// If the image is larger than `maxDimension` on its longest edge,
/// re-encode it at that size as JPEG quality 0.8. Otherwise return the
/// original bytes unchanged. Keeps history row loads fast and the
/// SwiftData store small.
private func resizeImageDataIfNeeded(_ data: Data, maxDimension: CGFloat) -> Data? {
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else { return data }
    let longest = max(image.size.width, image.size.height)
    if longest <= maxDimension { return data }
    let scale = maxDimension / longest
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    let resized = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: newSize))
    }
    return resized.jpegData(compressionQuality: 0.8)
    #else
    return data
    #endif
}

/// Convenience: run both phases and return the top candidate, fully
/// enriched. Kept for any caller that wants the original one-shot API.
func searchLandmark(
    query: String,
    userLocation: CLLocation? = nil
) async -> LandmarkResult? {
    let candidates = await searchLandmarkCandidates(
        query: query,
        userLocation: userLocation
    )
    guard let first = candidates.first else { return nil }
    return await enrichLandmark(first, query: query)
}

/// Comprehensive list of words that indicate a physical place. Used
/// both by `isLandmarkType` (P31 label check) and by
/// `titleContainsPlaceWord` (title fallback for missing Wikidata).
/// Shared so the two checks stay in sync.
private let placeIndicators: [String] = [
    // Structures
    "building", "structure", "house", "home", "mansion", "estate",
    "villa", "cottage", "cabin", "lodge", "inn", "hotel", "resort",
    "manor", "homestead", "grange", "farmstead",
    "tower", "castle", "fortress", "fort", "citadel", "palace",
    "temple", "church", "cathedral", "chapel", "basilica",
    "mosque", "synagogue", "shrine", "monastery", "abbey",
    "bridge", "dam", "lighthouse", "windmill", "mill", "barn",
    "warehouse", "factory", "courthouse", "capitol", "statehouse",
    "library", "hospital", "prison", "penitentiary", "jail",
    "barracks", "armory", "arsenal", "observatory",
    "school", "university", "college", "academy", "campus",
    "museum", "gallery", "theater", "theatre", "amphitheater",
    "arena", "stadium", "pavilion",
    "station", "terminal", "airport", "depot",
    "pier", "wharf", "dock", "marina", "harbor", "port", "boardwalk",
    "tunnel", "aqueduct", "canal",
    "monument", "memorial", "statue", "sculpture", "obelisk",
    "cemetery", "burial", "mausoleum", "tomb",
    "plaza", "square", "promenade",
    // Natural features
    "mountain", "hill", "peak", "summit", "ridge", "cliff", "bluff",
    "valley", "canyon", "gorge", "ravine", "glen",
    "river", "creek", "stream", "spring", "lake", "pond",
    "lagoon", "reservoir", "waterfall", "falls",
    "island", "peninsula", "cape", "bay", "cove", "inlet",
    "beach", "shore", "coast", "rock", "ledge", "point",
    "cave", "cavern", "grotto",
    "forest", "wood", "grove", "jungle",
    "desert", "dune", "mesa", "butte", "plateau",
    "glacier", "volcano", "crater", "geyser",
    "swamp", "marsh", "wetland",
    // Areas / regions
    "park", "garden", "arboretum", "botanical",
    "zoo", "aquarium", "sanctuary", "preserve",
    "reserve", "refuge", "conservation",
    "farm", "ranch", "plantation", "vineyard", "winery", "orchard",
    "mine", "quarry",
    "trail", "path", "route",
    "battlefield", "battleground",
    "district", "neighborhood", "quarter",
    "site", "grounds", "complex", "compound",
    // Settlements
    "city", "town", "village", "hamlet", "settlement",
    "borough", "township", "municipality",
    "county", "parish", "territory",
    // Infrastructure
    "road", "highway", "freeway", "turnpike",
    "railway", "railroad",
    // Catch-all landmark words
    "landmark", "heritage", "historic",
    "ruins", "archaeological",
    "camp", "campground"
]

/// Returns true if the title and query are a close match — either the
/// title contains the full query or the query contains the full title.
/// Used to prioritize exact matches over distance-based ranking.
private func isCloseTitleMatch(_ title: String, query: String) -> Bool {
    let t = title.lowercased()
    return t.contains(query) || query.contains(t)
}

/// Returns true if the given title contains at least one
/// place-indicating word. Used as a fallback when an article has no
/// Wikidata type — "Choco Taco" has no place word → rejected, while
/// "Fort Nathan Hale" contains "fort" → kept.
private func titleContainsPlaceWord(_ title: String) -> Bool {
    let lower = title.lowercased()
    for word in placeIndicators {
        if lower.contains(word) { return true }
    }
    return false
}

/// Stopwords stripped when tokenizing query/title text for overlap
/// scoring. These carry no discriminative weight for landmark names.
private let queryStopwords: Set<String> = [
    "the", "and", "for", "from", "that", "this", "with", "into", "onto",
    "near", "over", "under", "about", "around",
    "state", "national", "historic", "historical", "site", "area",
    "park", "landmark", "monument"
]

/// Split a query or title into significant lowercase tokens: letters
/// and digits only, ≥3 characters, minus stopwords.
private func significantTokens(_ text: String) -> [String] {
    return text
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { $0.count >= 3 && !queryStopwords.contains($0) }
}

/// Returns true if the article title shares enough significant tokens
/// with the query to be considered a reasonable title match. Protects
/// against Wikipedia's full-text search returning articles that
/// coincidentally mention the query in their body text without being
/// about it.
///
/// Rule: at least `ceil(queryTokens.count / 2)` of the query's
/// significant tokens must appear in the title. A search for "fort
/// Nathan Hale" (3 tokens) requires 2 title matches, so "East Haven"
/// (0 matches) is dropped while "Nathan Hale Homestead" (2 matches)
/// and "Fort Nathan Hale" (3 matches) are kept.
///
/// If the query has no significant tokens (too short, all stopwords),
/// the filter passes everything rather than rejecting it all.
private func titleMatchesQuery(query: String, title: String) -> Bool {
    let queryTokens = significantTokens(query)
    guard !queryTokens.isEmpty else { return true }

    let lowerTitle = title.lowercased()
    let matchCount = queryTokens.reduce(into: 0) { count, token in
        if lowerTitle.contains(token) { count += 1 }
    }
    let required = max(1, (queryTokens.count + 1) / 2)
    return matchCount >= required
}

/// Decide whether a Wikidata P31 ("instance of") label represents
/// something that could plausibly be on a brown roadside sign.
///
/// Three-pass strategy:
///   1. **Blocklist** — fast-reject known non-landmark exact labels
///      and phrase patterns (bands, films, food, people, etc.)
///   2. **Place-indicator whitelist** — accept if the label contains
///      ANY word that implies a physical place (building, park,
///      mountain, river, museum, fort, etc.)
///   3. **Default reject** — if the label survived the blocklist but
///      has NO place indicator, it's probably something creative we
///      haven't blocked yet (ice cream treat, cultural tradition,
///      publicity stunt, etc.). Reject it.
///
/// Items with a nil P31 label (Wikidata didn't return a type) are
/// handled by the caller — they're accepted as "unknown, might be a
/// landmark". This function is only called when a label IS present.
private func isLandmarkType(_ label: String) -> Bool {
    let lower = label
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // --- Pass 1: explicit blocklist (fast reject) ---

    let exactBlocks: Set<String> = [
        "human", "band", "album", "song", "single", "film", "movie",
        "book", "novel", "food", "dish", "dog", "cat", "animal",
        "hoax", "prank", "mascot", "logo", "brand", "trademark",
        "software", "taxon", "species", "genus", "breed",
        "beverage", "drink", "cocktail", "recipe", "ingredient",
        "color", "colour", "language", "word", "currency",
        "business", "enterprise", "corporation"
    ]
    if exactBlocks.contains(lower) { return false }

    let phraseBlocks = [
        "musical group", "musical ensemble", "rock band", "musical work",
        "musical composition", "music album",
        "television series", "tv series", "film series", "web series",
        "anime series", "television program",
        "given name", "family name", "fictional character",
        "dog breed", "cat breed", "breed of",
        "food product", "food chain", "fast food",
        "chain store", "retail chain", "restaurant chain",
        "advertising campaign", "advertising character",
        "April Fools", "video game", "mobile game",
        "comic book", "comic strip", "comic series"
    ]
    for phrase in phraseBlocks {
        if lower.contains(phrase) { return false }
    }

    // --- Pass 2: place-indicator whitelist ---
    // If the label contains any word that implies a physical location,
    // it's almost certainly a landmark. This is the primary acceptance
    // path — much more robust than trying to enumerate every possible
    // non-landmark Wikidata type. Uses the shared `placeIndicators`
    // array defined at file scope.
    for indicator in placeIndicators {
        if lower.contains(indicator) { return true }
    }

    // --- Pass 3: default reject ---
    // The label survived the blocklist but has no place indicator.
    // This catches everything creative we haven't explicitly blocked:
    // "novelty ice cream treat", "cultural tradition",
    // "publicity stunt", "recurring event", "day of celebration", etc.
    return false
}
