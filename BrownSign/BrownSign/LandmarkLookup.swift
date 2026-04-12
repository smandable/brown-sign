//
//  LandmarkLookup.swift
//  BrownSign
//
//  SwiftData model for a persisted landmark lookup. Replaces the
//  starter Item.swift.
//

import Foundation
import SwiftData

@Model
final class LandmarkLookup {
    var id: UUID
    var rawSignText: String
    var resolvedTitle: String
    /// Polished 2–3 sentence version shown on the result card and history row.
    var summary: String
    /// Full unpolished Wikipedia/NPS extract shown on the detail view.
    var rawSummary: String
    var pageURLString: String
    var source: String
    var date: Date
    var imageData: Data?
    /// Remote article image URL (Wikipedia pageimages thumbnail), if any.
    var articleImageURLString: String?

    // Wikidata enrichment
    var latitude: Double?
    var longitude: Double?
    var inceptionYear: Int?
    var wikidataType: String?

    // Confidence scores
    var externalConfidence: Double?   // Google Knowledge Graph
    var onDeviceMatchScore: Double?   // FoundationModels

    init(
        rawSignText: String,
        resolvedTitle: String,
        summary: String,
        rawSummary: String,
        pageURLString: String,
        source: String,
        imageData: Data? = nil,
        articleImageURLString: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        inceptionYear: Int? = nil,
        wikidataType: String? = nil,
        externalConfidence: Double? = nil,
        onDeviceMatchScore: Double? = nil
    ) {
        self.id = UUID()
        self.rawSignText = rawSignText
        self.resolvedTitle = resolvedTitle
        self.summary = summary
        self.rawSummary = rawSummary
        self.pageURLString = pageURLString
        self.source = source
        self.date = Date()
        self.imageData = imageData
        self.articleImageURLString = articleImageURLString
        self.latitude = latitude
        self.longitude = longitude
        self.inceptionYear = inceptionYear
        self.wikidataType = wikidataType
        self.externalConfidence = externalConfidence
        self.onDeviceMatchScore = onDeviceMatchScore
    }

    var pageURL: URL? { URL(string: pageURLString) }
    var articleImageURL: URL? {
        guard let s = articleImageURLString else { return nil }
        return URL(string: s)
    }
    var hasCoordinates: Bool { latitude != nil && longitude != nil }
}
