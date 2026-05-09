import XCTest
@testable import CoordinateParser

final class CoordinateParserTests: XCTestCase {

    // MARK: - DMS

    func testParsesDMSFromDrakesBayLeadSentence() {
        // The actual lead sentence of the Wikipedia article that
        // motivated this fallback. Wikidata Q17514736 has no P625, but
        // the article publishes the coord inline.
        let text = """
        Drakes Bay Oyster Company was an oyster farm and restaurant \
        formerly located at the shoreline and in Drakes Estero at \
        38°04'57.3\"N 122°55'55.0\"W, a bay within Point Reyes National \
        Seashore, on the West Marin coast of Marin County.
        """
        let result = parseCoordinatesFromText(text)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 38.0826, accuracy: 0.001)
        XCTAssertEqual(result.longitude, -122.9319, accuracy: 0.001)
    }

    func testParsesDMSWithoutSeconds() {
        let result = parseCoordinatesFromText("located near 40°45'N 73°59'W today")
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 40.75, accuracy: 0.01)
        XCTAssertEqual(result.longitude, -73.9833, accuracy: 0.01)
    }

    func testParsesDMSWithUnicodePrimes() {
        // Some Wikipedia articles use the typographic prime/double-prime
        // characters (U+2032 / U+2033) instead of ASCII '/".
        let text = "tower stands at 48\u{2032}51\u{2032}30\u{2033}N 2\u{2032}17\u{2032}40\u{2033}E"
        // Note: this exercises the prime normalization path. The exact
        // sample uses prime as the *degrees* delimiter though — our
        // pattern requires a literal °. Use a realistic mixed example:
        let realistic = "48°51'30\u{2033}N 2°17'40\u{2033}E"
        let result = parseCoordinatesFromText(realistic)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 48.8583, accuracy: 0.01)
        XCTAssertEqual(result.longitude, 2.2944, accuracy: 0.01)
        // The first sample (with prime as degree separator) is malformed
        // and should not parse — verify we don't accept it.
        XCTAssertNil(parseCoordinatesFromText(text))
    }

    func testDMSHandlesSouthernAndEasternHemispheres() {
        // Sydney Opera House: 33°51'31"S 151°12'51"E
        let text = "the building sits at 33°51'31\"S 151°12'51\"E on the harbour"
        let result = parseCoordinatesFromText(text)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, -33.8586, accuracy: 0.01)
        XCTAssertEqual(result.longitude, 151.2142, accuracy: 0.01)
    }

    func testDMSRejectsBothHemispheresOnSameAxis() {
        // Two N-tagged halves is malformed — bail rather than guess.
        XCTAssertNil(parseCoordinatesFromText("38°04'57.3\"N 122°55'55.0\"N"))
    }

    func testDMSAcceptsLonFirstWhenHemisphereDisambiguates() {
        // Lon-first ordering: hemisphere letters tell us which is which,
        // so the parser should still produce the right (lat, lon) pair.
        let text = "marker at 122°55'55.0\"W 38°04'57.3\"N"
        let result = parseCoordinatesFromText(text)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 38.0826, accuracy: 0.001)
        XCTAssertEqual(result.longitude, -122.9319, accuracy: 0.001)
    }

    // MARK: - Decimal with hemisphere

    func testParsesDecimalWithHemisphereLetters() {
        let text = "the lighthouse is at 38.0826° N, 122.9319° W in Marin"
        let result = parseCoordinatesFromText(text)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 38.0826, accuracy: 0.0001)
        XCTAssertEqual(result.longitude, -122.9319, accuracy: 0.0001)
    }

    func testParsesDecimalWithoutDegreeSymbol() {
        let result = parseCoordinatesFromText("plotted 51.5074 N 0.1278 W on the map")
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 51.5074, accuracy: 0.0001)
        XCTAssertEqual(result.longitude, -0.1278, accuracy: 0.0001)
    }

    // MARK: - Signed decimal pair

    func testParsesSignedDecimalPair() {
        let text = "GPS coords 38.0826, -122.9319 mark the spot"
        let result = parseCoordinatesFromText(text)
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.latitude, 38.0826, accuracy: 0.0001)
        XCTAssertEqual(result.longitude, -122.9319, accuracy: 0.0001)
    }

    func testSignedDecimalPairRejectsIntegerPairs() {
        // "Founded in 1934, with 1942 as a reference year" should NOT
        // false-match — the parser requires a decimal point in both
        // numbers to count as a coordinate.
        XCTAssertNil(parseCoordinatesFromText("Founded in 1934, 1942 expanded"))
    }

    func testSignedDecimalPairRejectsOutOfRange() {
        // Latitude >90 must not be accepted even if the syntax matches.
        XCTAssertNil(parseCoordinatesFromText("widget rated 95.5, -200.1 in spec"))
    }

    // MARK: - No match

    func testReturnsNilForUnrelatedText() {
        XCTAssertNil(parseCoordinatesFromText("Just a sentence with no coordinates."))
    }

    func testReturnsNilForEmptyString() {
        XCTAssertNil(parseCoordinatesFromText(""))
    }
}
