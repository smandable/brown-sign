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
    guard let data = await httpDataWithRetry(URLRequest(url: url)) else { return nil }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let extract = root["extract"] as? String,
          !extract.isEmpty else {
        return nil
    }
    return extract
}

/// Returns additional Wikipedia article images beyond the primary
/// thumbnail — used by the detail view's image carousel. Calls
/// `/api/rest_v1/page/media-list/{title}` and filters to gallery-
/// worthy images via Wikipedia's `showInGallery` flag (the same hint
/// MediaWiki itself uses to skip nav icons, audio file thumbnails,
/// and country-flag decorations). SVGs are also dropped — AsyncImage
/// doesn't render them natively and they're typically diagrams or
/// icons rather than photographs.
///
/// If `excluding` is supplied, any URL whose base file name matches
/// the excluded URL's base file name is skipped. We match on base
/// name (with the `Npx-` thumbnail-size prefix stripped) so that the
/// 600 px primary thumbnail and its original full-size sibling don't
/// both show up as duplicate slides.
///
/// Returns [] on any error or when the page has no extra media —
/// caller falls back to single-image rendering.
func wikipediaArticleImageURLs(
    for title: String,
    excluding excludedURL: URL? = nil
) async -> [URL] {
    let pathTitle = title.replacingOccurrences(of: " ", with: "_")
    guard let encoded = pathTitle.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
          ),
          let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/media-list/\(encoded)") else {
        return []
    }

    guard let data = await httpDataWithRetry(URLRequest(url: url)) else { return [] }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = root["items"] as? [[String: Any]] else {
        return []
    }

    let excludedBase = excludedURL.map(wikipediaImageBaseName)
    var seenBases = Set<String>()
    var urls: [URL] = []
    for item in items {
        guard let type = item["type"] as? String, type == "image" else { continue }
        guard let showInGallery = item["showInGallery"] as? Bool, showInGallery else { continue }
        // Prefer the original-size source. Fall back to the largest
        // srcset entry when `original` is missing.
        let sourceString: String?
        if let original = item["original"] as? [String: Any],
           let src = original["source"] as? String {
            sourceString = src
        } else if let srcset = item["srcset"] as? [[String: Any]],
                  let last = srcset.last,
                  let src = last["src"] as? String {
            sourceString = src
        } else {
            sourceString = nil
        }
        guard let source = sourceString,
              let imgURL = parseProtocolRelativeURL(source) else { continue }
        // Skip SVGs — AsyncImage can't render them and they're
        // usually diagrams rather than photographs.
        if imgURL.pathExtension.lowercased() == "svg" { continue }
        let base = wikipediaImageBaseName(imgURL)
        if let excludedBase, base == excludedBase { continue }
        if seenBases.contains(base) { continue }
        seenBases.insert(base)
        urls.append(imgURL)
    }
    return urls
}

/// Strips the `Npx-` thumbnail-size prefix off a Wikipedia image URL's
/// last path component, so a 600 px thumbnail and its full-size
/// sibling resolve to the same base name. Used to dedup the lead
/// image against the rest of the media list.
private func wikipediaImageBaseName(_ url: URL) -> String {
    let last = url.lastPathComponent
    if let range = last.range(of: #"^\d+px-"#, options: .regularExpression) {
        return String(last[range.upperBound...])
    }
    return last
}

/// Wikipedia's REST API returns protocol-relative URLs (`//upload…`).
/// Prepend `https:` so URL parsing succeeds; pass through fully-formed
/// URLs unchanged.
private func parseProtocolRelativeURL(_ src: String) -> URL? {
    if src.hasPrefix("//") {
        return URL(string: "https:" + src)
    }
    return URL(string: src)
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

struct WikiPageDetails {
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

/// Title-keyed variant of `wikipediaFetchPageDetails(pageIDs:)`. The
/// SPARQL Nearby flow gets Wikipedia article titles from Wikidata
/// sitelinks, not MediaWiki page IDs, so we hit the same endpoint with
/// `titles=` instead of `pageids=`. Same response shape; returned
/// dictionary is keyed by INPUT title — MediaWiki's normalization and
/// redirect chains are resolved internally so a caller looking up by
/// the Wikidata-sitelink title gets the right entry.
func wikipediaFetchPageDetailsByTitles(_ titles: [String]) async -> [String: WikiPageDetails] {
    guard !titles.isEmpty else { return [:] }
    let batches = stride(from: 0, to: titles.count, by: wikipediaPageDetailsBatchSize).map {
        Array(titles[$0..<min($0 + wikipediaPageDetailsBatchSize, titles.count)])
    }

    var combined = await withTaskGroup(of: [String: WikiPageDetails].self) { group in
        for batch in batches {
            group.addTask { await fetchPageDetailsBatchByTitles(batch) }
        }
        var acc: [String: WikiPageDetails] = [:]
        for await partial in group {
            acc.merge(partial) { _, new in new }
        }
        return acc
    }

    // Same REST extract fallback as the pageID path — articles whose
    // intro extract is empty (infobox-then-section-header layout) get
    // patched from the REST summary endpoint.
    let needsFallback: [String] = combined.compactMap { (key, d) in
        (d.extract.isEmpty && !d.isDisambiguation) ? key : nil
    }
    if !needsFallback.isEmpty {
        let patches: [(String, String)] = await withTaskGroup(of: (String, String)?.self) { group in
            for key in needsFallback {
                let title = combined[key]?.title ?? key
                group.addTask {
                    guard let fallback = await wikipediaRESTSummaryExtract(for: title) else {
                        return nil
                    }
                    return (key, fallback)
                }
            }
            var out: [(String, String)] = []
            for await entry in group {
                if let entry { out.append(entry) }
            }
            return out
        }
        for (key, extract) in patches {
            guard let existing = combined[key] else { continue }
            combined[key] = WikiPageDetails(
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

/// Fetches one batch of page details by title. Expects `titles.count <= 50`.
/// Returns a dictionary keyed by INPUT title — handles MediaWiki's
/// `normalized` and `redirects` arrays so a caller passing in the
/// Wikidata-sitelink title finds the entry under that exact key,
/// even when Wikipedia routes the title through normalization or a
/// redirect chain.
private func fetchPageDetailsBatchByTitles(_ titles: [String]) async -> [String: WikiPageDetails] {
    guard !titles.isEmpty else { return [:] }
    let titleList = titles.joined(separator: "|")
    guard let encoded = titleList.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts%7Cpageprops%7Cinfo%7Cpageimages&ppprop=disambiguation&inprop=url&exintro=1&explaintext=1&redirects=1&piprop=thumbnail&pithumbsize=600&titles=\(encoded)") else {
        return [:]
    }

    guard let data = await httpDataWithRetry(URLRequest(url: url)) else { return [:] }
    do {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = root["query"] as? [String: Any],
              let pages = queryObj["pages"] as? [String: Any] else {
            return [:]
        }

        // Build a map from canonical title back to the original input
        // title, walking the normalize → redirect chain so chained
        // rewrites still resolve to the caller's input string.
        var canonicalToOriginal: [String: String] = [:]
        if let norm = queryObj["normalized"] as? [[String: Any]] {
            for entry in norm {
                if let from = entry["from"] as? String,
                   let to = entry["to"] as? String {
                    canonicalToOriginal[to] = from
                }
            }
        }
        if let redirects = queryObj["redirects"] as? [[String: Any]] {
            for entry in redirects {
                if let from = entry["from"] as? String,
                   let to = entry["to"] as? String {
                    let original = canonicalToOriginal[from] ?? from
                    canonicalToOriginal[to] = original
                }
            }
        }

        var result: [String: WikiPageDetails] = [:]
        for (_, rawPage) in pages {
            guard let page = rawPage as? [String: Any],
                  let title = page["title"] as? String else { continue }
            let extract = page["extract"] as? String ?? ""
            let urlString = page["fullurl"] as? String
                ?? page["canonicalurl"] as? String
                ?? ""
            guard let pageURL = URL(string: urlString) else { continue }

            let pageprops = page["pageprops"] as? [String: Any]
            let isDisambiguation = pageprops?["disambiguation"] != nil

            var imageURL: URL?
            if let thumb = page["thumbnail"] as? [String: Any],
               let src = thumb["source"] as? String {
                imageURL = URL(string: src)
            }

            let details = WikiPageDetails(
                title: title,
                extract: extract,
                url: pageURL,
                imageURL: imageURL,
                isDisambiguation: isDisambiguation
            )
            // Key under both the canonical title AND the original
            // input title (when redirects/normalize rewrote it). The
            // caller can look up under whichever they have.
            result[title] = details
            if let original = canonicalToOriginal[title], original != title {
                result[original] = details
            }
        }
        return result
    } catch {
        return [:]
    }
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
