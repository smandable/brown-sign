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
        guard let label = pair.wd?.typeLabel else { return false }
        return !isLandmarkType(label)
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

    if userLocation != nil {
        // Stable sort: with-distance ascending, then without-distance at the end.
        built.sort { a, b in
            switch (a.distance, b.distance) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }
    }

    var results = built.map { $0.result }

    // 5. NPS fallback only if we got zero Wikipedia candidates.
    if results.isEmpty, let nps = await searchNPS(query: trimmed) {
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
    async let imageData  = downloadArticleImage(
        from: candidate.articleImageURL,
        title: candidate.title
    )

    let kg     = await kgScore
    let polish = await polished
    let match  = await matchScore
    let image  = await imageData

    return LandmarkResult(
        title: candidate.title,
        summary: polish,
        rawSummary: candidate.rawSummary,
        pageURL: candidate.pageURL,
        source: candidate.source,
        articleImageURL: candidate.articleImageURL,
        articleImageData: image,
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

/// Decide whether a Wikidata P31 ("instance of") label represents
/// something that could plausibly be on a brown roadside sign.
/// Permissive default: if we don't know, accept.
///
/// Uses two-tier matching so we don't accidentally block valid landmark
/// types like "human settlement" (villages, hamlets) just because the
/// label contains "human".
private func isLandmarkType(_ label: String) -> Bool {
    let lower = label
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Exact matches — block only if the whole label equals one of these.
    let exactBlocks: Set<String> = [
        // Music
        "band", "album", "song", "single", "extended play", "mixtape",
        // Film / TV / games
        "film", "movie", "documentary", "short film",
        "episode", "video game", "mobile game",
        // Print
        "book", "novel", "short story", "poem",
        "magazine", "newspaper", "manga", "comic book", "comic strip",
        // People / characters / names
        "human", "fictional character", "mythological character",
        "given name", "surname", "family name", "pseudonym",
        // Biology
        "taxon", "species", "genus", "breed",
        // Software / products
        "software", "mobile app", "web application",
        "operating system", "programming language",
        "brand", "trademark",
        // Abstract
        "idea", "concept", "theorem", "scientific theory",
        // Organizations that aren't places
        "business", "enterprise", "corporation"
    ]
    if exactBlocks.contains(lower) { return false }

    // Phrase matches — block if the label contains any of these.
    let phraseBlocks = [
        // Music groups of any flavor
        "musical group", "musical ensemble", "rock band", "punk band",
        "pop band", "rock group", "jazz band", "boy band", "girl group",
        "metal band", "hip hop group",
        "music album", "studio album", "live album", "compilation album",
        // TV / film
        "television series", "tv series", "television program",
        "tv program", "web series", "anime series",
        "film series", "film franchise",
        // Books / publishing
        "book series", "novel series", "comic series",
        // People / names — anything that says "given name" or "family name"
        // catches variants like "male given name", "surname in X".
        "given name", "family name",
        // Events (generally not landmarks — a "battle" or "festival" at
        // location X doesn't point to X itself).
        "sports event", "music festival",
        // Commercial entities
        "chain store", "retail chain", "restaurant chain"
    ]
    for phrase in phraseBlocks {
        if lower.contains(phrase) { return false }
    }
    return true
}
