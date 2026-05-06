//
//  WikidataLandmarkSearch.swift
//  BrownSign
//
//  Wikidata SPARQL primary fetch for the Nearby tab. Replaces the
//  Wikipedia-geosearch + place-word filter pipeline with a single
//  server-side query that returns only items with a heritage
//  designation (P1435) or a curated landmark P31 type (recursive via
//  P279*). Brown signs are essentially the real-world analog of NRHP
//  listings; SPARQL lets us filter by exactly that signal, server-
//  side, instead of fetching every Wikipedia article in radius and
//  sorting through it client-side.
//
//  Hydration of summary text and thumbnail still uses the Wikipedia
//  REST endpoints (SPARQL doesn't return article extracts). The
//  operating-institution gate runs as a second pass — Seymour High
//  School has a heritage designation on its NRHP-listed building so
//  SPARQL surfaces it, then the gate drops it on P576 absence.
//
//  WDQS reliability: the query service has a 60-second timeout and can
//  return 503 under load. On any error this returns []; callers
//  should be prepared to render an empty Nearby state.
//

import Foundation
import CoreLocation

struct WikidataLandmarkHit {
    let qid: String
    /// Wikipedia article title, decoded from the Wikidata sitelink URL
    /// path — percent-decoded, underscores replaced with spaces.
    let wikipediaTitle: String
    /// Wikidata P625 coordinate.
    let coordinate: Coordinate
}

/// Curated landmark P31 allowlist. Used with `wdt:P31/wdt:P279*` so
/// subclasses (state park → park, art museum → museum, theatre →
/// theatre building) come along for free. Items covered by P1435
/// don't need to be enumerated here — they pass via the heritage
/// branch of the UNION.
private let landmarkP31QIDs: [String] = [
    "Q33506",      // museum
    "Q22698",      // park
    "Q4989906",    // monument
    "Q386426",     // memorial
    "Q839954",     // archaeological site
    "Q15243209",   // historic district
    "Q9259",       // World Heritage Site
    "Q1058834",    // National Wildlife Refuge
    "Q2085381",    // National Historic Landmark
    "Q570116",     // tourist attraction
    "Q39614",      // cemetery
    "Q39715",      // lighthouse
    "Q12280",      // bridge
    "Q57821",      // fortification
    "Q44613",      // monastery
    "Q23413",      // castle
    "Q16560",      // palace
    "Q19776",      // battlefield
    "Q1361932",    // covered bridge
    "Q1763547",    // windmill
    "Q35509",      // cave
    "Q5004679",    // natural arch
    "Q108325",     // chapel
    "Q1196645",    // stately home
    "Q207320",     // historic house museum
    "Q24354",      // theatre building (Westport Country Playhouse)
    "Q41501",      // auditorium
    "Q178561",     // battle (event-as-place: "Battle of Norwalk")
    "Q5113893"     // university campus building (Harkness Tower, Yale Bowl)
]

/// Oversized result limit. Bumped above the on-screen cap so dense
/// areas (New Haven returns ~125 hits in testing) don't get clipped
/// before client-side distance ordering. Caller still truncates to
/// the display cap.
private let sparqlResultLimit = 300

/// WDQS recommends a descriptive User-Agent. Without one, queries can
/// be aggressively rate-limited.
private let wdqsUserAgent = "BrownSign-iOS/1.2 (https://github.com/seanmandable/brown-sign)"

/// Fetches landmark candidates within `radiusKm` of (`lat`, `lon`)
/// from the Wikidata Query Service. Returns hits with QID, Wikipedia
/// article title, and coordinate. Hydration of summary/thumbnail and
/// the operating-institution gate run as separate passes in the caller.
///
/// Retries on transient errors (5xx + network blips) via
/// `httpDataWithRetry` — WDQS occasionally returns 502/503 when
/// load-balancing or backend-restarting and the next retry almost
/// always succeeds.
///
/// Returns `nil` on transient transport failure (HTTP retries
/// exhausted, URL/encoding error). Returns `[]` only when the
/// endpoint successfully answered with zero hits — i.e. the area
/// is genuinely empty. The caller distinguishes the two so a
/// transient WDQS hiccup surfaces as a retryable "service
/// unavailable" state rather than an indistinguishable
/// "No landmarks nearby" — the latter would be wrong (and
/// historically caused intermittent false-empty reports).
func discoverLandmarksViaSPARQL(
    centerLat: Double,
    centerLon: Double,
    radiusKm: Double
) async -> [WikidataLandmarkHit]? {
    let valuesBlock = landmarkP31QIDs.map { "wd:\($0)" }.joined(separator: " ")
    let query = """
    SELECT DISTINCT ?item ?article ?coord WHERE {
      SERVICE wikibase:around {
        ?item wdt:P625 ?coord .
        bd:serviceParam wikibase:center "Point(\(centerLon) \(centerLat))"^^geo:wktLiteral .
        bd:serviceParam wikibase:radius "\(radiusKm)" .
      }
      {
        ?item wdt:P1435 [] .
      } UNION {
        ?item wdt:P31/wdt:P279* ?root .
        VALUES ?root { \(valuesBlock) }
      }
      ?article schema:about ?item ;
               schema:isPartOf <https://en.wikipedia.org/> .
    }
    LIMIT \(sparqlResultLimit)
    """

    guard let encoded = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
          ),
          let url = URL(string: "https://query.wikidata.org/sparql?format=json&query=\(encoded)") else {
        return nil
    }

    var request = URLRequest(url: url)
    request.setValue(wdqsUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
    // 12 s per attempt. WDQS normally answers in <2 s for this kind
    // of geo-spatial query, but the radius branch occasionally blows
    // past 8 s under load — the previous 8 s ceiling was firing as a
    // false-empty for users (saw "No landmarks nearby" when the
    // endpoint just hadn't returned yet). 12 s covers the long tail
    // without compounding into a 30 s+ wait.
    request.timeoutInterval = 12

    // 3 attempts. Worst-case wait is `12 + 0.5 + 12 + 1.5 + 12 = 38 s`,
    // but the modal case is one of the early attempts succeeding —
    // the third attempt only runs if both 1 and 2 failed, which
    // catches WDQS's rarer multi-second hiccups that 2 attempts
    // dropped on the floor.
    guard let data = await httpDataWithRetry(request, maxAttempts: 3) else { return nil }
    return parseSPARQLBindings(data)
}

/// Parses the `results.bindings` array of a WDQS JSON response into
/// `[WikidataLandmarkHit]`. Returns [] on malformed JSON or missing
/// fields — matches the function's "graceful empty on any error"
/// contract.
private func parseSPARQLBindings(_ data: Data) -> [WikidataLandmarkHit] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let results = root["results"] as? [String: Any],
          let bindings = results["bindings"] as? [[String: Any]] else {
        return []
    }

    var hits: [WikidataLandmarkHit] = []
    for binding in bindings {
        guard let item = binding["item"] as? [String: Any],
              let itemValue = item["value"] as? String,
              let article = binding["article"] as? [String: Any],
              let articleValue = article["value"] as? String,
              let coordObj = binding["coord"] as? [String: Any],
              let coordValue = coordObj["value"] as? String else {
            continue
        }
        guard let qid = itemValue.split(separator: "/").last.map(String.init),
              qid.hasPrefix("Q") else {
            continue
        }
        let lastPath = articleValue.split(separator: "/").last.map(String.init) ?? ""
        guard let decoded = lastPath.removingPercentEncoding else { continue }
        let title = decoded.replacingOccurrences(of: "_", with: " ")
        guard let coord = parseSPARQLPoint(coordValue) else { continue }
        hits.append(WikidataLandmarkHit(
            qid: qid,
            wikipediaTitle: title,
            coordinate: coord
        ))
    }
    return hits
}

/// Parses a WKT `Point(lon lat)` literal as Wikidata returns from
/// P625. Lon comes first in WKT.
private func parseSPARQLPoint(_ value: String) -> Coordinate? {
    guard value.hasPrefix("Point("), value.hasSuffix(")") else { return nil }
    let inner = value.dropFirst("Point(".count).dropLast(")".count)
    let parts = inner.split(separator: " ")
    guard parts.count == 2,
          let lon = Double(parts[0]),
          let lat = Double(parts[1]) else {
        return nil
    }
    return Coordinate(latitude: lat, longitude: lon)
}
