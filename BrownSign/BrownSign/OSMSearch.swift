//
//  OSMSearch.swift
//  BrownSign
//
//  OpenStreetMap landmark lookup via the Overpass API. Third data source
//  alongside Wikipedia and NPS — covers the signed-but-Wikipedia-less
//  landscape: small parks, monuments, memorials, scenic viewpoints,
//  historic markers that the other two sources don't know about.
//
//  Two entry points:
//    - `searchOpenStreetMapNearby` for the scan pipeline (name-filtered).
//    - `openStreetMapNearbyCandidates` for the Nearby discovery tab.
//
//  Overpass is free and needs no auth, but it IS shared community
//  infrastructure. We set a specific User-Agent, bound server-side via
//  `timeout:`, bound client-side via a URLSession timeout, and fail
//  gracefully so the rest of the pipeline keeps working if Overpass is
//  slow or overloaded.
//

import Foundation
import CoreLocation

/// One hit from Overpass. Mirrors `WikiResult` / `NPSResult` structurally
/// so the orchestrator can consume all three sources uniformly.
struct OSMResult {
    let title: String
    /// Summary synthesized from OSM tags (no text description in the
    /// raw data). For elements that link to Wikipedia via a `wikipedia`
    /// tag, the orchestrator replaces this with the Wikipedia extract.
    let summary: String
    /// Points at the Wikipedia article when the element has a
    /// `wikipedia` tag; falls back to the OSM feature page otherwise.
    let pageURL: URL
    /// OSM elements rarely carry image URLs directly. The orchestrator
    /// resolves one via Wikipedia REST when `wikipediaTitle` is set.
    let imageURL: URL?
    let latitude: Double
    let longitude: Double
    /// Great-circle distance from the query point (meters). Only filled
    /// in the Nearby discovery flow; the text-scan flow leaves it nil.
    let distanceMeters: Double?
    /// If the OSM `wikipedia` tag is present and English, the stripped
    /// article title (e.g. "Liberty Bell"). Callers use this to route
    /// the candidate through the Wikipedia pipeline for a higher-quality
    /// summary and image.
    let wikipediaTitle: String?
    /// Primary OSM tag that classified this as a landmark
    /// ("historic", "tourism", "leisure", "natural"). Used to drop
    /// lifestyle tourism (hotel, guest_house) when filtering.
    let primaryCategory: String
    /// Subtype within the primary category ("monument", "viewpoint",
    /// "peak", etc.). Shown in the synthesized summary for OSM-only
    /// results so the user gets a sense of what the pin is.
    let subtype: String?
}

// MARK: - Public entry points

/// Name-filtered nearby OSM lookup used by the scan pipeline. Fetches
/// all candidate features within `radiusMeters` and keeps those whose
/// name contains the query (case-insensitive). Small radius + name
/// filter keeps result counts in the single digits on the scan path.
func searchOpenStreetMapNearby(
    query: String,
    latitude: Double,
    longitude: Double,
    radiusMeters: Int = 10_000
) async -> [OSMResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let all = await fetchOverpassLandmarks(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters
    )
    guard !all.isEmpty else { return [] }

    let needle = trimmed.lowercased()
    return all.filter { $0.title.lowercased().contains(needle) }
}

/// Discovery-mode entry point for the Nearby tab. Returns up to `limit`
/// named landmarks sorted by distance. No name filter — the user is
/// browsing, not searching.
func openStreetMapNearbyCandidates(
    latitude: Double,
    longitude: Double,
    radiusMeters: Int = 10_000,
    limit: Int = 40
) async -> [OSMResult] {
    let all = await fetchOverpassLandmarks(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters
    )
    guard !all.isEmpty else { return [] }

    // Already distance-sorted inside `fetchOverpassLandmarks`.
    return Array(all.prefix(limit))
}

// MARK: - Overpass query + parse

/// Single round-trip to Overpass that returns all landmark candidates
/// within the radius. Shared by both entry points; the caller is
/// responsible for name-filter / limit / slicing.
private func fetchOverpassLandmarks(
    latitude: Double,
    longitude: Double,
    radiusMeters: Int
) async -> [OSMResult] {
    let clampedRadius = min(max(radiusMeters, 100), 25_000)
    let ql = overpassQuery(
        latitude: latitude,
        longitude: longitude,
        radiusMeters: clampedRadius
    )

    guard let data = await executeOverpassQuery(ql) else { return [] }
    let parsed = parseOverpassElements(data)

    // Sort by distance from the query point so callers can slice/prefix.
    let user = CLLocation(latitude: latitude, longitude: longitude)
    let withDistance = parsed.map { raw -> OSMResult in
        let loc = CLLocation(latitude: raw.latitude, longitude: raw.longitude)
        let d = user.distance(from: loc)
        return OSMResult(
            title: raw.title,
            summary: raw.summary,
            pageURL: raw.pageURL,
            imageURL: raw.imageURL,
            latitude: raw.latitude,
            longitude: raw.longitude,
            distanceMeters: d,
            wikipediaTitle: raw.wikipediaTitle,
            primaryCategory: raw.primaryCategory,
            subtype: raw.subtype
        )
    }
    return withDistance.sorted {
        ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity)
    }
}

/// Builds the Overpass QL query string. Scopes to:
///   - `historic=*` (monument, memorial, ruins, fort, archaeological_site, …)
///   - a curated subset of `tourism=*` (attractions and cultural venues
///     only; deliberately excludes hotel / guest_house / camp_site /
///     information which are lifestyle-tourism rather than landmarks).
///   - `leisure=park` (any named park)
///   - `natural=` peaks / waterfalls / volcanoes / arches / cave entrances
///     — the named natural features that actually tend to get brown signs.
///
/// All clauses require `["name"]` so unnamed features never return.
private func overpassQuery(
    latitude: Double,
    longitude: Double,
    radiusMeters: Int
) -> String {
    let around = "around:\(radiusMeters),\(latitude),\(longitude)"
    // `nwr` = node | way | relation. `out center tags;` collapses ways
    // to a single center coordinate so we don't need to pull geometry.
    return """
    [out:json][timeout:20];
    (
      nwr["historic"]["name"](\(around));
      nwr["tourism"~"^(attraction|viewpoint|museum|artwork|zoo|aquarium|gallery|theme_park)$"]["name"](\(around));
      nwr["leisure"="park"]["name"](\(around));
      nwr["natural"~"^(peak|waterfall|volcano|arch|cave_entrance)$"]["name"](\(around));
    );
    out center tags;
    """
}

/// POSTs the Overpass QL query and returns the raw response body.
/// 25 s request timeout — Overpass bounds itself at 20 s via the
/// `timeout:` directive in the query, this gives network overhead a
/// little headroom. Any failure returns nil so the orchestrator
/// degrades to Wikipedia + NPS only.
private func executeOverpassQuery(_ ql: String) async -> Data? {
    guard let url = URL(string: "https://overpass-api.de/api/interpreter") else {
        return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 25
    request.setValue(
        "application/x-www-form-urlencoded; charset=utf-8",
        forHTTPHeaderField: "Content-Type"
    )
    // Overpass's usage policy asks for an identifiable User-Agent so
    // abusive clients can be contacted/blocked individually. Generic
    // URLSession defaults sometimes get rate-limited more aggressively.
    request.setValue(
        "BrownSign-iOS/1.1 (+https://apps.apple.com/us/app/brown-sign/id6762070205)",
        forHTTPHeaderField: "User-Agent"
    )

    // Form-encoded `data=<query>` per Overpass's POST convention.
    let body = "data=" + (ql.addingPercentEncoding(
        withAllowedCharacters: .urlQueryAllowed
    ) ?? ql)
    request.httpBody = body.data(using: .utf8)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            return nil
        }
        return data
    } catch {
        return nil
    }
}

/// Parsed intermediate without `distanceMeters` — filled in by the caller
/// once it has the user's coordinate. Separated so the parser stays pure.
private struct ParsedOSMElement {
    let title: String
    let summary: String
    let pageURL: URL
    let imageURL: URL?
    let latitude: Double
    let longitude: Double
    let wikipediaTitle: String?
    let primaryCategory: String
    let subtype: String?
}

/// Decodes the Overpass JSON response. Each element has lat/lon
/// directly (nodes) or nested under `center` (ways/relations with
/// `out center`). Drops elements without a resolvable lat/lon or name.
private func parseOverpassElements(_ data: Data) -> [ParsedOSMElement] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let elements = root["elements"] as? [[String: Any]] else {
        return []
    }

    // Dedupe by name: Overpass can return the same named feature as both
    // a node and a way (e.g. a building's outline + a reception point).
    // We only need one pin per name in a given radius.
    var seenTitles = Set<String>()
    var out: [ParsedOSMElement] = []

    for element in elements {
        guard let tags = element["tags"] as? [String: String],
              let name = tags["name"], !name.isEmpty else {
            continue
        }

        let (lat, lon) = extractCoordinate(from: element)
        guard let lat, let lon else { continue }

        // Canonical lowercase title key — "liberty bell" == "Liberty Bell".
        let key = name.lowercased()
        if seenTitles.contains(key) { continue }
        seenTitles.insert(key)

        let (category, subtype) = primaryCategory(from: tags)

        let wikipediaTitle = parseWikipediaTag(tags["wikipedia"])
        let pageURL: URL
        if let wikiTitle = wikipediaTitle,
           let u = wikipediaPageURL(for: wikiTitle) {
            pageURL = u
        } else if let elementType = element["type"] as? String,
                  let id = element["id"] as? Int,
                  let u = URL(string: "https://www.openstreetmap.org/\(elementType)/\(id)") {
            pageURL = u
        } else {
            continue
        }

        let summary = synthesizeSummary(
            tags: tags,
            category: category,
            subtype: subtype
        )

        out.append(ParsedOSMElement(
            title: name,
            summary: summary,
            pageURL: pageURL,
            imageURL: nil,
            latitude: lat,
            longitude: lon,
            wikipediaTitle: wikipediaTitle,
            primaryCategory: category,
            subtype: subtype
        ))
    }
    return out
}

/// Pulls lat/lon from either a bare node or a way/relation with `center`.
private func extractCoordinate(
    from element: [String: Any]
) -> (lat: Double?, lon: Double?) {
    if let lat = element["lat"] as? Double,
       let lon = element["lon"] as? Double {
        return (lat, lon)
    }
    if let center = element["center"] as? [String: Any],
       let lat = center["lat"] as? Double,
       let lon = center["lon"] as? Double {
        return (lat, lon)
    }
    return (nil, nil)
}

/// Resolves which tag classified this element as a landmark, and its
/// specific subtype. The query clauses are mutually exclusive in
/// priority order — `historic` wins over `tourism` etc. — so we check
/// in that same order here.
private func primaryCategory(
    from tags: [String: String]
) -> (category: String, subtype: String?) {
    if let v = tags["historic"] {
        return ("historic", v == "yes" ? nil : v)
    }
    if let v = tags["tourism"] {
        return ("tourism", v == "yes" ? nil : v)
    }
    if tags["leisure"] == "park" {
        return ("leisure", "park")
    }
    if let v = tags["natural"] {
        return ("natural", v == "yes" ? nil : v)
    }
    return ("unknown", nil)
}

/// Parses the `wikipedia` tag's language prefix. The OSM convention is
/// `<lang>:<article title>` (e.g. `en:Liberty Bell`). Only English is
/// useful to us — other languages' titles don't sitelink through our
/// Wikipedia pipeline cleanly.
private func parseWikipediaTag(_ raw: String?) -> String? {
    guard let raw, let colon = raw.firstIndex(of: ":") else { return nil }
    let lang = raw[..<colon]
    guard lang == "en" else { return nil }
    let title = String(raw[raw.index(after: colon)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
}

/// URL to the English Wikipedia article for the given title.
private func wikipediaPageURL(for title: String) -> URL? {
    let normalized = title.replacingOccurrences(of: " ", with: "_")
    guard let encoded = normalized.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
    ) else {
        return nil
    }
    return URL(string: "https://en.wikipedia.org/wiki/\(encoded)")
}

/// Hand-rolled one-sentence summary from the tag bag. Used as-is for
/// OSM-only results; the orchestrator overwrites it with the Wikipedia
/// extract when `wikipediaTitle` is set. Intentionally terse — the
/// underlying data is too thin to pretend it's an article.
private func synthesizeSummary(
    tags: [String: String],
    category: String,
    subtype: String?
) -> String {
    // Prefer a natural-language `description` tag when mappers supplied one.
    if let desc = tags["description"], !desc.isEmpty {
        return desc
    }

    let typeLabel = subtype.map { $0.replacingOccurrences(of: "_", with: " ") }

    var parts: [String] = []
    switch category {
    case "historic":
        parts.append("Historic \(typeLabel ?? "site")")
    case "tourism":
        parts.append(typeLabel.map { $0.capitalized } ?? "Attraction")
    case "leisure":
        parts.append("Park")
    case "natural":
        parts.append("Natural feature: \(typeLabel ?? "landmark")")
    default:
        parts.append("Landmark")
    }

    if let city = tags["addr:city"], !city.isEmpty {
        parts.append("in \(city)")
    } else if let state = tags["addr:state"], !state.isEmpty {
        parts.append("in \(state)")
    }

    var sentence = parts.joined(separator: " ")
    sentence += " (identified via OpenStreetMap)."
    return sentence
}
