//
//  NarrationScript.swift
//  BrownSign
//
//  What Listen reads aloud: a landmark's name, where it is relative to
//  the listener, then its Wikipedia introduction cleaned up for speech
//  and trimmed to about a minute.
//

import Foundation
import CoreLocation
import NaturalLanguage

/// One landmark queued for narration. A value copied out of a Nearby
/// result or a saved lookup, so the queue never holds SwiftData objects
/// that could be deleted from History mid-drive.
nonisolated struct NarrationItem: Identifiable, Hashable, Sendable {
    /// Canonical page URL string: the same key Nearby dedups on and
    /// `HiddenLandmark` and the heard log are keyed by.
    let id: String
    let title: String
    /// The article introduction (the unpolished extract), read after the lead.
    let summary: String
    let coordinate: Coordinate?
    let imageURL: URL?
    /// Persisted image bytes, when the landmark is a saved lookup.
    let imageData: Data?

    init(result: LandmarkResult) {
        id = result.pageURL.absoluteString
        title = result.title
        summary = result.rawSummary.isEmpty ? result.summary : result.rawSummary
        coordinate = result.coordinates
        imageURL = result.articleImageURL
        imageData = result.articleImageData
    }

    @MainActor
    init(lookup: LandmarkLookup) {
        id = lookup.pageURLString
        title = lookup.resolvedTitle
        summary = lookup.rawSummary.isEmpty ? lookup.summary : lookup.rawSummary
        if let lat = lookup.latitude, let lon = lookup.longitude {
            coordinate = Coordinate(latitude: lat, longitude: lon)
        } else {
            coordinate = nil
        }
        imageURL = lookup.articleImageURL
        // The article image first; the user's own sign photo beats nothing.
        imageData = lookup.articleImageData ?? lookup.imageData
    }

    private init(copying other: NarrationItem, summary: String) {
        id = other.id
        title = other.title
        self.summary = summary
        coordinate = other.coordinate
        imageURL = other.imageURL
        imageData = other.imageData
    }

    func withSummary(_ summary: String) -> NarrationItem {
        NarrationItem(copying: self, summary: summary)
    }

    var location: CLLocation? {
        coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

/// Where a landmark sits relative to the listener's direction of travel.
nonisolated enum RelativeDirection {
    case ahead, left, right, behind

    var phrase: String {
        switch self {
        case .ahead: "ahead"
        case .left: "on your left"
        case .right: "on your right"
        case .behind: "behind you"
        }
    }

    /// Nil unless the listener is moving fast enough for GPS course to
    /// mean something: below ~9 mph (walking, a parking lot, stopped at a
    /// light) the course swings around and "on your left" would be a guess.
    static func of(_ coordinate: Coordinate, from listener: CLLocation) -> RelativeDirection? {
        guard listener.course >= 0,
              listener.courseAccuracy >= 0, listener.courseAccuracy <= 45,
              listener.speed >= 4 else { return nil }
        let diff = angleBetween(bearing(from: listener.coordinate, to: coordinate), listener.course)
        switch abs(diff) {
        case ...35: return .ahead
        case ...145: return diff > 0 ? .right : .left
        default: return .behind
        }
    }

    /// Initial great-circle bearing from `a` to `b`, degrees clockwise from north.
    static func bearing(from a: CLLocationCoordinate2D, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed difference `bearing - course`, folded into -180...180
    /// (positive = clockwise of the course, i.e. to the right).
    static func angleBetween(_ bearing: Double, _ course: Double) -> Double {
        var diff = (bearing - course).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }
}

nonisolated enum NarrationScript {
    /// Longest introduction read aloud, cut back to the last whole
    /// sentence that fits. ~1,100 characters is about a minute at the
    /// default speaking rate: long enough to tell the story, short enough
    /// that driving past a landmark doesn't turn into a lecture.
    static let maxBodyCharacters = 1_100

    /// Beyond this, "About 380 miles away" is trivia rather than help
    /// (a History find from another trip), so the lead drops the distance.
    static let maxSpokenDistance: CLLocationDistance = 80_000

    /// Past a quarter mile a landmark is usually out of sight, and "on your
    /// left" doesn't mean anything to a driver, so the lead only gives a
    /// direction inside this (the "Less than a quarter mile away" range).
    static let maxDirectionDistance: CLLocationDistance = 1609.344 / 4

    enum LeadStyle {
        /// "Old State House. Less than a quarter mile away, on your left."
        /// Farther out: "Old State House. About a mile away."
        case plain
        /// Automatic narration: "Coming up on your right: Old State House."
        /// Farther out: "Nearby: Old State House, about a mile away."
        case approaching
    }

    /// The full script: the lead, then the cleaned, trimmed introduction.
    static func script(for item: NarrationItem, from listener: CLLocation?, style: LeadStyle) -> String {
        let body = trimmed(cleaned(item.summary), maxCharacters: maxBodyCharacters)
        return [lead(for: item, from: listener, style: style), body]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func lead(for item: NarrationItem, from listener: CLLocation?, style: LeadStyle) -> String {
        let title = spokenTitle(item.title)
        guard let listener, let coordinate = item.coordinate,
              let landmark = item.location else {
            return "\(title)."
        }
        let meters = listener.distance(from: landmark)
        guard meters <= maxSpokenDistance else { return "\(title)." }
        let distance = spokenDistance(meters)
        let direction = meters < maxDirectionDistance ? RelativeDirection.of(coordinate, from: listener) : nil
        switch style {
        case .plain:
            if let direction {
                return "\(title). \(distance), \(direction.phrase)."
            }
            return "\(title). \(distance)."
        case .approaching:
            if let direction, direction != .behind {
                return "Coming up \(direction.phrase): \(title)."
            }
            return "Nearby: \(title), \(distance.lowercasedFirstLetter)."
        }
    }

    /// "Elm Street Historic District (Hartford, Connecticut)" → "Elm Street
    /// Historic District": Wikipedia's disambiguation suffix is for telling
    /// articles apart on a page, and reads oddly aloud.
    static func spokenTitle(_ title: String) -> String {
        let stripped = title.replacingOccurrences(of: #"\s*\([^()]*\)\s*$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? title : stripped
    }

    /// Distance the way a person would say it: "About half a mile away",
    /// "About 400 meters away". Follows the same measurement-system check
    /// as the on-screen distances.
    static func spokenDistance(_ meters: CLLocationDistance) -> String {
        if Locale.current.measurementSystem == .metric {
            if meters < 950 {
                let hundreds = max(1, Int((meters / 100).rounded())) * 100
                return "About \(hundreds) meters away"
            }
            let km = Int((meters / 1_000).rounded())
            return km == 1 ? "About a kilometer away" : "About \(km) kilometers away"
        }
        let miles = meters / 1609.344
        if miles < 0.25 { return "Less than a quarter mile away" }
        if miles < 0.75 { return "About half a mile away" }
        if miles < 1.5 { return "About a mile away" }
        return "About \(Int(miles.rounded())) miles away"
    }

    /// Plain-text extract → something that sounds right read aloud.
    static func cleaned(_ raw: String) -> String {
        var text = removingReaderOnlyParentheticals(raw)
        // Bracketed notes: "[a]", "[citation needed]".
        text = text.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
        // "c. 1850" / "ca. 1850": the synthesizer reads the letter C.
        text = text.replacingOccurrences(
            of: #"(^|[\s(])(?:c|ca)\.\s*(?=\d)"#,
            with: "$1circa ",
            options: [.regularExpression, .caseInsensitive]
        )
        // Paragraph breaks and runs of whitespace → single spaces, then
        // tidy the " ," / " ." a removal can leave behind.
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.;:])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops parentheticals written for readers, not listeners: IPA and
    /// respelled pronunciations ("(/ˈhɑːrtfərd/ HART-fərd)"), audio-clip
    /// cues ("listen"), and ones a cleanup already emptied. Keeps the rest
    /// ("(built 1796)", "(French: …)"). Innermost first, two passes, which
    /// covers the one level of nesting Wikipedia intros actually use.
    static func removingReaderOnlyParentheticals(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"\s*\(([^()]*)\)"#) else { return text }
        var result = text
        for _ in 0..<2 {
            let ns = result as NSString
            let matches = pattern.matches(in: result, range: NSRange(location: 0, length: ns.length))
            let mutable = NSMutableString(string: result)
            var changed = false
            for match in matches.reversed() where isReaderOnly(ns.substring(with: match.range(at: 1))) {
                mutable.replaceCharacters(in: match.range, with: "")
                changed = true
            }
            guard changed else { break }
            result = mutable as String
        }
        return result
    }

    private static func isReaderOnly(_ inner: String) -> Bool {
        let lower = inner.lowercased()
        if lower.contains("listen") || lower.contains("pronounc") { return true }
        // IPA is slash-delimited in Wikipedia intros.
        if inner.contains("/") { return true }
        if inner.unicodeScalars.contains(where: isPhonetic) { return true }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    /// IPA Extensions, Spacing Modifier Letters (ˈ ˌ ː) and Phonetic Extensions.
    private static func isPhonetic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0250...0x02FF).contains(scalar.value) || (0x1D00...0x1DBF).contains(scalar.value)
    }

    /// Cut back to the last whole sentence within `maxCharacters`. When
    /// even the first sentence runs long it's kept whole: a finished
    /// thought beats one cut off mid-clause.
    static func trimmed(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var end: String.Index?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if end == nil || text.distance(from: text.startIndex, to: range.upperBound) <= maxCharacters {
                end = range.upperBound
                return true
            }
            return false
        }
        guard let end else { return text }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// "About a mile away" → "about a mile away", for mid-sentence use.
    nonisolated var lowercasedFirstLetter: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
