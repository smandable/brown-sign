//
//  HiddenLandmark.swift
//  BrownSign
//
//  SwiftData record for a Nearby landmark the user has chosen to hide.
//  Keyed by canonical page URL — the same identifier the Nearby fetch
//  uses for dedup — so filtering is a straight set membership check.
//  Title is denormalized so the "Hidden landmarks" sheet can render
//  without re-fetching the underlying landmark.
//

import Foundation
import SwiftData

@Model
final class HiddenLandmark {
    @Attribute(.unique) var pageURLString: String
    var title: String
    /// Optional so SwiftData lightweight migration accepts it for any
    /// pre-existing rows that were created before this field existed —
    /// adding a non-optional String can silently fail migration and
    /// degrade the entire model container.
    var summary: String?
    var articleImageURLString: String?
    var articleImageData: Data?
    var dateHidden: Date

    init(
        pageURLString: String,
        title: String,
        summary: String? = nil,
        articleImageURLString: String? = nil,
        articleImageData: Data? = nil
    ) {
        self.pageURLString = pageURLString
        self.title = title
        self.summary = summary
        self.articleImageURLString = articleImageURLString
        self.articleImageData = articleImageData
        self.dateHidden = Date()
    }
}
