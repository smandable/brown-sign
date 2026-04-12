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
            summary: String(d.extract.prefix(500)),
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
                  let title = entry["title"] as? String else { return nil }
            return NearbyPage(pageID: pageid, title: title)
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
            summary: String(page.extract.prefix(500)),
            pageURL: page.url,
            imageURL: page.imageURL
        ))
    }
    return results
}

// MARK: - Step 0: strip noise words before searching

private func cleanWikipediaQuery(_ raw: String) -> String {
    let patterns = [
        #"site of"#,
        #"est\.\s*\d{4}"#,
        #"historic"#,
        #"national"#,
        #"state"#
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

private func wikipediaFetchPageDetails(pageIDs: [Int]) async -> [Int: WikiPageDetails] {
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
