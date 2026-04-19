//
//  WikipediaSearch.swift
//  BrownSign
//
//  Wikipedia lookup with disambiguation handling.
//
//    1. list=search     → top 5 ranked candidates (with pageids)
//    2. prop=extracts   → batch fetch intro + pageprops + url for all 5
//    3. pick the first candidate that is NOT a disambiguation page
//
//  This fixes the "X may refer to…" problem that plain opensearch hits
//  for ambiguous landmark names like "Wadsworth Mansion".
//

import Foundation

struct WikiResult {
    let title: String
    let summary: String
    let pageURL: URL
    /// Wikipedia article thumbnail (from prop=pageimages), if any.
    let imageURL: URL?
}

/// Convenience: return only the first non-disambiguation candidate.
/// Most callers should prefer `searchWikipediaCandidates(query:)` so they
/// can filter by Wikidata entity type (e.g. reject bands, films, people).
func searchWikipedia(query: String) async -> WikiResult? {
    return (await searchWikipediaCandidates(query: query)).first
}

/// Returns non-disambiguation Wikipedia articles within `radiusMeters` of
/// the given coordinate whose titles contain the query text (case
/// insensitive). Used by the orchestrator to prefer genuinely-nearby
/// landmarks over whatever Wikipedia text-ranks as globally popular.
///
/// Internally this is a two-step fetch:
///   1. `list=geosearch` for nearby page list (titles + pageids only)
///   2. client-side title filter, then `wikipediaFetchPageDetails` for
///      the matches to get extracts + pageimages + disambiguation flag
///
/// The naive one-shot `generator=geosearch + prop=pageimages` approach
/// silently drops thumbnails for pages beyond the `pilimit` cap (~50),
/// which in dense areas (hundreds of geo-tagged articles within 10 km)
/// means articles at index 55+ lose their thumbnail field even though
/// Wikipedia has one. Splitting into two calls keeps thumbnail lookups
/// well under the cap.
///
/// Notes on Wikipedia's geosearch API limits:
///   - Maximum radius is **10,000 meters** — larger values return an error.
///   - Maximum `gslimit` is 500. Use a large value because dense areas
///     can have hundreds of geo-tagged articles within a few km.
func searchWikipediaNearby(
    query: String,
    latitude: Double,
    longitude: Double,
    radiusMeters: Int = 10_000
) async -> [WikiResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }

    // Step 1: get nearby page list (distance-ordered).
    let nearby = await wikipediaGeosearchPageList(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters
    )
    guard !nearby.isEmpty else { return [] }

    // Step 2: title-match filter (client side).
    let needle = trimmedQuery.lowercased()
    let matching = nearby.filter { $0.title.lowercased().contains(needle) }
    guard !matching.isEmpty else { return [] }

    // Step 3: batch fetch details (extracts + thumbnails + disambiguation
    // flag). Landmark queries typically yield < 10 matches, well under
    // pilimit=50, so one call is enough.
    let pageIDs = matching.map(\.pageID)
    let details = await wikipediaFetchPageDetails(pageIDs: pageIDs)
    guard !details.isEmpty else { return [] }

    // Step 4: assemble, preserving geosearch order (distance-ascending).
    var results: [WikiResult] = []
    for page in matching {
        guard let d = details[page.pageID] else { continue }
        if d.isDisambiguation { continue }
        results.append(WikiResult(
            title: d.title,
            summary: truncateAtWordBoundary(d.extract, maxLength: 500),
            pageURL: d.url,
            imageURL: d.imageURL
        ))
    }
    return results
}

// MARK: - Nearby discovery (no query filter)

/// One result from the discovery-mode geosearch: a nearby Wikipedia
/// article with coordinates and the user-distance already filled in.
/// Separate from `WikiResult` because discovery always has geographic
/// context, while the plain text-search result doesn't.
struct NearbyWikiCandidate {
    let title: String
    let summary: String
    let pageURL: URL
    let imageURL: URL?
    let latitude: Double
    let longitude: Double
    /// Great-circle distance from the user, in meters (from the
    /// geosearch response).
    let distanceMeters: Double
}

/// Returns up to `limit` nearby Wikipedia articles (distance-sorted, no
/// query filter). Discovery-mode entry point for the Nearby tab.
///
/// Two-step fetch: geosearch for the page list, then batch page-details
/// for extracts + thumbnails + disambiguation flags. Only the first
/// `limit` pages are hydrated; geosearch in a dense area can return
/// hundreds, but most users won't scroll past ~30.
func wikipediaNearbyCandidates(
    latitude: Double,
    longitude: Double,
    radiusMeters: Int = 10_000,
    limit: Int = 40
) async -> [NearbyWikiCandidate] {
    let nearby = await wikipediaGeosearchPageList(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters
    )
    guard !nearby.isEmpty else { return [] }

    let capped = Array(nearby.prefix(limit))
    let details = await wikipediaFetchPageDetails(pageIDs: capped.map(\.pageID))
    guard !details.isEmpty else { return [] }

    var results: [NearbyWikiCandidate] = []
    for page in capped {
        guard let d = details[page.pageID] else { continue }
        if d.isDisambiguation { continue }
        results.append(NearbyWikiCandidate(
            title: d.title,
            summary: truncateAtWordBoundary(d.extract, maxLength: 500),
            pageURL: d.url,
            imageURL: d.imageURL,
            latitude: page.latitude,
            longitude: page.longitude,
            distanceMeters: page.distanceMeters
        ))
    }
    return results
}

// MARK: - Plain geosearch (no page details)

private struct NearbyPage {
    let pageID: Int
    let title: String
    let latitude: Double
    let longitude: Double
    /// Wikipedia-provided great-circle distance from the query coordinate,
    /// in meters. Already distance-ascending in the response.
    let distanceMeters: Double
}

/// Truncates text at the last word boundary before `maxLength` and
/// appends "…" if the original was longer. Short text is returned as-is.
private func truncateAtWordBoundary(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else { return text }
    var truncated = String(text.prefix(maxLength))
    if let lastSpace = truncated.lastIndex(of: " ") {
        truncated = String(truncated[..<lastSpace])
    }
    return truncated.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

private func wikipediaGeosearchPageList(
    latitude: Double,
    longitude: Double,
    radiusMeters: Int
) async -> [NearbyPage] {
    let clampedRadius = min(max(radiusMeters, 10), 10_000)
    let coord = "\(latitude)|\(longitude)"
    guard let encodedCoord = coord.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&list=geosearch&gscoord=\(encodedCoord)&gsradius=\(clampedRadius)&gslimit=500") else {
        return []
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = root["query"] as? [String: Any],
              let geosearch = queryObj["geosearch"] as? [[String: Any]] else {
            return []
        }
        return geosearch.compactMap { entry in
            guard let pageid = entry["pageid"] as? Int,
                  let title = entry["title"] as? String,
                  let lat = entry["lat"] as? Double,
                  let lon = entry["lon"] as? Double else { return nil }
            let dist = (entry["dist"] as? Double) ?? 0
            return NearbyPage(
                pageID: pageid,
                title: title,
                latitude: lat,
                longitude: lon,
                distanceMeters: dist
            )
        }
    } catch {
        return []
    }
}

/// Returns the ranked list of non-disambiguation Wikipedia candidates for
/// the given query. Up to 15 entries. The orchestrator then uses Wikidata
/// P31 type-filtering to pick the first one that's actually a landmark.
func searchWikipediaCandidates(query: String) async -> [WikiResult] {
    let cleaned = cleanWikipediaQuery(query)
    guard !cleaned.isEmpty else { return [] }

    let candidates = await wikipediaSearchCandidates(cleaned)
    guard !candidates.isEmpty else { return [] }

    let details = await wikipediaFetchPageDetails(pageIDs: candidates.map { $0.pageID })
    guard !details.isEmpty else { return [] }

    var results: [WikiResult] = []
    for candidate in candidates {
        guard let page = details[candidate.pageID] else { continue }
        if page.isDisambiguation { continue }
        // Belt-and-braces: a few non-disambiguation pages still start with
        // "X may refer to" — treat those as disambiguation too.
        if page.extract.range(of: #"\bmay refer to\b"#,
                              options: [.regularExpression, .caseInsensitive]) != nil {
            continue
        }
        results.append(WikiResult(
            title: page.title,
            summary: truncateAtWordBoundary(page.extract, maxLength: 500),
            pageURL: page.url,
            imageURL: page.imageURL
        ))
    }
    return results
}

// MARK: - REST summary fallbacks

/// REST fallback for when the legacy intro-extract call
/// (`exintro=1&explaintext=1`) returns "" for an article that actually
/// has body content. Some articles lead with an infobox straight into
/// a section header, leaving `exintro` nothing before the first `<h2>`
/// to extract — the REST summary endpoint uses a smarter heuristic
/// that still finds usable text. Returns nil when REST also has no
/// extract (true stubs, redirects that dropped content, etc.).
func wikipediaRESTSummaryExtract(for title: String) async -> String? {
    let pathTitle = title.replacingOccurrences(of: " ", with: "_")
    guard let encoded = pathTitle.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
          ),
          let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
        return nil
    }
    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extract = root["extract"] as? String,
              !extract.isEmpty else {
            return nil
        }
        return extract
    } catch {
        return nil
    }
}

/// Returns the best article image URL via the Wikipedia REST summary
/// endpoint (`/api/rest_v1/page/summary/{title}`). Used as a fallback
/// when the legacy `prop=pageimages` call returned no thumbnail — REST
/// has a smarter image-selection heuristic that catches pages where
/// `pageimages` returns nothing: fair-use lead images, articles whose
/// only images live inline in the body, or pages `pageimages` simply
/// hasn't indexed yet. Prefers `originalimage` (high-res, resized
/// client-side) and falls back to the 320-wide `thumbnail`.
/// Returns nil on any failure; callers treat the image as optional.
func wikipediaRESTSummaryImageURL(for title: String) async -> URL? {
    // REST takes the title in the URL path with underscores for spaces.
    // URL path encoding (not query encoding) — parens, commas, colons
    // are legal, but "/" and "?" in titles must be percent-encoded.
    let pathTitle = title.replacingOccurrences(of: " ", with: "_")
    guard let encoded = pathTitle.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
          ),
          let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
        return nil
    }
    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let original = root["originalimage"] as? [String: Any],
           let src = original["source"] as? String,
           let u = URL(string: src) {
            return u
        }
        if let thumb = root["thumbnail"] as? [String: Any],
           let src = thumb["source"] as? String,
           let u = URL(string: src) {
            return u
        }
        return nil
    } catch {
        return nil
    }
}

// MARK: - Step 0: strip noise words before searching

/// Light cleanup for the Wikipedia search query. Only strips patterns
/// that are genuinely noise on brown signs and would never be part of
/// an official name (e.g. "SITE OF", "EST. 1776").
///
/// Previously this also stripped "state", "national", and "historic",
/// which broke searches like "Eastern State Penitentiary" (→ "Eastern
/// Penitentiary") and "Grand Canyon National Park" (→ "Grand Canyon
/// Park"). Those words are part of many official landmark names and
/// should NOT be removed — Apple Intelligence normalization handles
/// the intelligent cleanup upstream.
private func cleanWikipediaQuery(_ raw: String) -> String {
    let patterns = [
        #"\bsite of\b"#,
        #"\best\.\s*\d{4}\b"#
    ]
    var result = raw
    for pattern in patterns {
        result = result.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    // Collapse whitespace.
    result = result.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Step 1: list=search

private struct WikiCandidate {
    let pageID: Int
    let title: String
}

private func wikipediaSearchCandidates(_ query: String) async -> [WikiCandidate] {
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&list=search&srlimit=15&srsearch=\(encoded)") else {
        return []
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = root["query"] as? [String: Any],
              let searchList = queryObj["search"] as? [[String: Any]] else {
            return []
        }
        return searchList.compactMap { entry -> WikiCandidate? in
            guard let pageid = entry["pageid"] as? Int,
                  let title = entry["title"] as? String else {
                return nil
            }
            return WikiCandidate(pageID: pageid, title: title)
        }
    } catch {
        return []
    }
}

// MARK: - Step 2: batch fetch extracts + pageprops + url by pageid

private struct WikiPageDetails {
    let title: String
    let extract: String
    let url: URL
    let imageURL: URL?
    let isDisambiguation: Bool
}

/// MediaWiki's anonymous API caps `pageids=` at 50 per request —
/// passing more returns an error and no usable data. Our Nearby
/// flow wants to hydrate ~100 candidates, so we batch.
private let wikipediaPageDetailsBatchSize = 50

private func wikipediaFetchPageDetails(pageIDs: [Int]) async -> [Int: WikiPageDetails] {
    guard !pageIDs.isEmpty else { return [:] }

    // Chunk into batches that stay under the 50-ID anon limit, and
    // fan them out in parallel so a two-batch request is only one
    // round-trip worth of latency.
    let batches = stride(from: 0, to: pageIDs.count, by: wikipediaPageDetailsBatchSize).map {
        Array(pageIDs[$0..<min($0 + wikipediaPageDetailsBatchSize, pageIDs.count)])
    }

    var combined = await withTaskGroup(of: [Int: WikiPageDetails].self) { group in
        for batch in batches {
            group.addTask { await fetchPageDetailsBatch(pageIDs: batch) }
        }
        var acc: [Int: WikiPageDetails] = [:]
        for await partial in group {
            acc.merge(partial) { _, new in new }
        }
        return acc
    }

    // Fill in empty extracts via REST. `exintro=1` returns "" for the
    // small set of articles that jump straight from an infobox into a
    // section header, but those articles have body text the REST
    // summary heuristic can find. Skip disambiguation pages — empty
    // there is intentional.
    let needsFallback: [(Int, String)] = combined.compactMap { id, d in
        (d.extract.isEmpty && !d.isDisambiguation) ? (id, d.title) : nil
    }
    if !needsFallback.isEmpty {
        let patches: [(Int, String)] = await withTaskGroup(of: (Int, String)?.self) { group in
            for (id, title) in needsFallback {
                group.addTask {
                    guard let fallback = await wikipediaRESTSummaryExtract(for: title) else {
                        return nil
                    }
                    return (id, fallback)
                }
            }
            var out: [(Int, String)] = []
            for await entry in group {
                if let entry { out.append(entry) }
            }
            return out
        }
        for (id, extract) in patches {
            guard let existing = combined[id] else { continue }
            combined[id] = WikiPageDetails(
                title: existing.title,
                extract: extract,
                url: existing.url,
                imageURL: existing.imageURL,
                isDisambiguation: existing.isDisambiguation
            )
        }
    }

    return combined
}

/// Fetches one page-details batch. Expects `pageIDs.count <= 50`.
private func fetchPageDetailsBatch(pageIDs: [Int]) async -> [Int: WikiPageDetails] {
    guard !pageIDs.isEmpty else { return [:] }
    let idList = pageIDs.map(String.init).joined(separator: "|")
    guard let encoded = idList.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts%7Cpageprops%7Cinfo%7Cpageimages&ppprop=disambiguation&inprop=url&exintro=1&explaintext=1&redirects=1&piprop=thumbnail&pithumbsize=600&pageids=\(encoded)") else {
        return [:]
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = root["query"] as? [String: Any],
              let pages = queryObj["pages"] as? [String: Any] else {
            return [:]
        }

        var result: [Int: WikiPageDetails] = [:]
        for (_, rawPage) in pages {
            guard let page = rawPage as? [String: Any],
                  let pageid = page["pageid"] as? Int,
                  let title = page["title"] as? String else {
                continue
            }
            let extract = page["extract"] as? String ?? ""
            let urlString = page["fullurl"] as? String
                ?? page["canonicalurl"] as? String
                ?? ""
            guard let pageURL = URL(string: urlString) else { continue }

            let pageprops = page["pageprops"] as? [String: Any]
            let isDisambiguation = pageprops?["disambiguation"] != nil

            // Optional article thumbnail.
            var imageURL: URL?
            if let thumb = page["thumbnail"] as? [String: Any],
               let src = thumb["source"] as? String {
                imageURL = URL(string: src)
            }

            result[pageid] = WikiPageDetails(
                title: title,
                extract: extract,
                url: pageURL,
                imageURL: imageURL,
                isDisambiguation: isDisambiguation
            )
        }
        return result
    } catch {
        return [:]
    }
}
