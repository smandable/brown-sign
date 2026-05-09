//
//  CoordinateParser.swift
//  BrownSign
//
//  Pure-logic regex parser for coordinate strings that appear in
//  Wikipedia article extracts. Used as the last-resort fallback when
//  neither Wikidata P625 nor MediaWiki `prop=coordinates` returns a
//  structured location for a landmark — e.g. Drakes Bay Oyster
//  Company (Wikidata Q17514736) has no P31 and no P625, but its
//  Wikipedia lead reads "located at 38°04'57.3"N 122°55'55.0"W".
//
//  Recognized formats:
//    - DMS:     `38°04'57.3"N 122°55'55.0"W`
//               (also accepts curly quotes, U+2032/U+2033 prime
//                marks, optional spaces, optional seconds, and a
//                `,` or `/` separator between lat and lon)
//    - Decimal: `38.0826° N, 122.9319° W`
//               `38.0826 N 122.9319 W`
//               `38.0826, -122.9319` (signed pair, no hemisphere)
//
//  Returns `(lat, lon)` as plain Doubles so this file has no
//  dependency on CoreLocation or the project's `Coordinate` type —
//  callers wrap it. Keeps the file trivially testable from a
//  separate Swift Package without touching the Xcode project.
//
//  Intentionally narrow. Doesn't try to parse coords embedded in
//  URL params, infobox tables, or weird hyphenated forms — just the
//  prose patterns Wikipedia article leads actually use.
//

import Foundation

/// Best-effort coordinate extraction from arbitrary article text.
/// Tries DMS first (more specific, less likely to false-match),
/// then decimal. Returns `nil` when nothing parses.
public func parseCoordinatesFromText(_ text: String) -> (latitude: Double, longitude: Double)? {
    if let dms = parseDMSCoordinates(text) { return dms }
    if let decimal = parseDecimalCoordinates(text) { return decimal }
    return nil
}

// MARK: - DMS

private func parseDMSCoordinates(_ text: String) -> (Double, Double)? {
    // Normalize prime/quote variants so the regex below stays simple.
    let normalized = text
        .replacingOccurrences(of: "\u{2032}", with: "'")  // ′ prime
        .replacingOccurrences(of: "\u{2033}", with: "\"") // ″ double prime
        .replacingOccurrences(of: "\u{2019}", with: "'")  // ’ right single quote
        .replacingOccurrences(of: "\u{201D}", with: "\"") // ” right double quote

    // One DMS half: degrees ° minutes ' [seconds[.frac]"]? hemisphere.
    // Hemisphere is mandatory in this branch — that's the strong signal
    // that "38°04'57"N" is a coordinate and not "38° lobster" or a temp
    // reading. Seconds are optional (some articles publish DD°MM'H only).
    //
    // Regex literal uses standard string interpolation (not a raw
    // string) so the `'` and `"` stay simple — the source-side prime
    // normalization above already collapsed Unicode primes to ASCII.
    let half = "(\\d{1,3})°\\s*(\\d{1,2})'\\s*(?:(\\d{1,2}(?:\\.\\d+)?)\"?\\s*)?([NSEWnsew])"
    let pattern = "\(half)\\s*[, /]?\\s*\(half)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

    let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    guard let match = regex.firstMatch(in: normalized, range: range),
          match.numberOfRanges == 9 else { return nil }

    func substr(_ idx: Int) -> String? {
        let r = match.range(at: idx)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: normalized) else {
            return nil
        }
        return String(normalized[swiftRange])
    }

    // Group layout: 1-4 = first half (deg, min, sec?, hemi); 5-8 = second.
    guard let d1 = substr(1).flatMap(Double.init),
          let m1 = substr(2).flatMap(Double.init),
          let h1 = substr(4),
          let d2 = substr(5).flatMap(Double.init),
          let m2 = substr(6).flatMap(Double.init),
          let h2 = substr(8) else { return nil }
    let s1 = substr(3).flatMap(Double.init) ?? 0
    let s2 = substr(7).flatMap(Double.init) ?? 0

    guard let v1 = dmsToDecimal(degrees: d1, minutes: m1, seconds: s1, hemisphere: h1),
          let v2 = dmsToDecimal(degrees: d2, minutes: m2, seconds: s2, hemisphere: h2) else {
        return nil
    }

    // Order in prose is usually lat then lon, but a careless writer can
    // flip them. Use the hemisphere letter to disambiguate: N/S = lat,
    // E/W = lon. If both halves agree on one axis (e.g. both N), the
    // input is malformed — bail rather than guessing.
    let h1IsLat = isLatHemisphere(h1)
    let h2IsLat = isLatHemisphere(h2)
    guard h1IsLat != h2IsLat else { return nil }

    let lat = h1IsLat ? v1 : v2
    let lon = h1IsLat ? v2 : v1
    guard isValidLatitude(lat), isValidLongitude(lon) else { return nil }
    return (lat, lon)
}

private func dmsToDecimal(
    degrees: Double,
    minutes: Double,
    seconds: Double,
    hemisphere: String
) -> Double? {
    guard degrees >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else {
        return nil
    }
    let magnitude = degrees + minutes / 60 + seconds / 3600
    switch hemisphere.uppercased() {
    case "N", "E": return magnitude
    case "S", "W": return -magnitude
    default: return nil
    }
}

// MARK: - Decimal

private func parseDecimalCoordinates(_ text: String) -> (Double, Double)? {
    if let withHemis = parseDecimalWithHemisphere(text) { return withHemis }
    return parseSignedDecimalPair(text)
}

private func parseDecimalWithHemisphere(_ text: String) -> (Double, Double)? {
    // `(-)?DDD(.DDD)? °? <hemi>` — degree symbol optional, sign optional.
    let half = #"(-?\d{1,3}(?:\.\d+)?)\s*°?\s*([NSEWnsew])"#
    let pattern = "\(half)\\s*[, /]?\\s*\(half)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges == 5 else { return nil }

    func substr(_ idx: Int) -> String? {
        let r = match.range(at: idx)
        guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
    guard let n1 = substr(1).flatMap(Double.init),
          let h1 = substr(2),
          let n2 = substr(3).flatMap(Double.init),
          let h2 = substr(4) else { return nil }

    guard let v1 = applyHemisphere(magnitude: n1, hemisphere: h1),
          let v2 = applyHemisphere(magnitude: n2, hemisphere: h2) else {
        return nil
    }

    let h1IsLat = isLatHemisphere(h1)
    let h2IsLat = isLatHemisphere(h2)
    guard h1IsLat != h2IsLat else { return nil }

    let lat = h1IsLat ? v1 : v2
    let lon = h1IsLat ? v2 : v1
    guard isValidLatitude(lat), isValidLongitude(lon) else { return nil }
    return (lat, lon)
}

private func applyHemisphere(magnitude: Double, hemisphere: String) -> Double? {
    switch hemisphere.uppercased() {
    case "N", "E": return magnitude
    case "S", "W": return -magnitude
    default: return nil
    }
}

/// Signed-pair fallback: `38.0826, -122.9319`. Requires both numbers
/// to look coord-shaped (decimal point, valid range) so date pairs
/// like "1934, 1942" don't false-match.
private func parseSignedDecimalPair(_ text: String) -> (Double, Double)? {
    let pattern = #"(-?\d{1,3}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: range)
    for match in matches where match.numberOfRanges == 3 {
        guard let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text),
              let lat = Double(text[r1]),
              let lon = Double(text[r2]),
              isValidLatitude(lat), isValidLongitude(lon) else { continue }
        return (lat, lon)
    }
    return nil
}

// MARK: - Helpers

private func isLatHemisphere(_ s: String) -> Bool {
    let u = s.uppercased()
    return u == "N" || u == "S"
}

private func isValidLatitude(_ value: Double) -> Bool {
    value >= -90 && value <= 90
}

private func isValidLongitude(_ value: Double) -> Bool {
    value >= -180 && value <= 180
}
