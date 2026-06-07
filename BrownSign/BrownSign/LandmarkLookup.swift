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
    /// Downloaded article image bytes (persisted locally so history rows
    /// never have to re-fetch from the network).
    var articleImageData: Data?

    // Wikidata enrichment
    var latitude: Double?
    var longitude: Double?
    var inceptionYear: Int?
    var wikidataType: String?

    // Confidence score
    var onDeviceMatchScore: Double?   // FoundationModels match judgment

    init(
        rawSignText: String,
        resolvedTitle: String,
        summary: String,
        rawSummary: String,
        pageURLString: String,
        source: String,
        imageData: Data? = nil,
        articleImageURLString: String? = nil,
        articleImageData: Data? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        inceptionYear: Int? = nil,
        wikidataType: String? = nil,
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
        self.articleImageData = articleImageData
        self.latitude = latitude
        self.longitude = longitude
        self.inceptionYear = inceptionYear
        self.wikidataType = wikidataType
        self.onDeviceMatchScore = onDeviceMatchScore
    }

    var pageURL: URL? { URL(string: pageURLString) }
    var articleImageURL: URL? {
        guard let s = articleImageURLString else { return nil }
        return URL(string: s)
    }
    var hasCoordinates: Bool { latitude != nil && longitude != nil }
}

extension LandmarkLookup {
    /// Inserts a new lookup or updates the existing one keyed on the
    /// result's canonical page URL. Updating bumps `date` so the row
    /// moves back to the top of History.
    ///
    /// Title/summary/source/image-URL/coordinates always refresh to the
    /// latest result. The enrichment fields (inception year, type,
    /// match score) refresh ONLY when the new result actually
    /// carries them — a later pass that came back without enrichment
    /// must not wipe a value an earlier pass found. (This is the
    /// previously-divergent behaviour: the Scan copy used to overwrite
    /// these unconditionally, so a re-save with nil enrichment cleared
    /// them; the Nearby copy preserved them. Preserving is correct — the
    /// page is the same landmark either way.)
    ///
    /// `rawSignText` and `capturedThumb` are only touched when supplied,
    /// so the Nearby flow (which has neither) never clears the user's
    /// earlier captured photo or the original OCR text.
    @MainActor
    @discardableResult
    static func upsert(
        result res: LandmarkResult,
        in context: ModelContext,
        rawSignText: String? = nil,
        capturedThumb: Data? = nil
    ) -> LandmarkLookup {
        let key = res.pageURL.absoluteString
        let descriptor = FetchDescriptor<LandmarkLookup>(
            predicate: #Predicate { $0.pageURLString == key }
        )
        if let existing = try? context.fetch(descriptor).first {
            if let rawSignText { existing.rawSignText = rawSignText }
            existing.resolvedTitle = res.title
            existing.summary = res.summary
            existing.rawSummary = res.rawSummary
            existing.source = res.source
            existing.articleImageURLString = res.articleImageURL?.absoluteString
            // Overwrite the persisted image bytes only when the fresh
            // search actually fetched new ones — preserve the prior copy
            // if this enrichment pass happened to fail.
            if let newData = res.articleImageData { existing.articleImageData = newData }
            existing.latitude = res.coordinates?.latitude
            existing.longitude = res.coordinates?.longitude
            if let year = res.inceptionYear { existing.inceptionYear = year }
            if let type = res.wikidataType { existing.wikidataType = type }
            if let m = res.onDeviceMatchScore { existing.onDeviceMatchScore = m }
            if let capturedThumb { existing.imageData = capturedThumb }
            existing.date = Date()
            return existing
        }

        let lookup = LandmarkLookup(
            rawSignText: rawSignText ?? "",
            resolvedTitle: res.title,
            summary: res.summary,
            rawSummary: res.rawSummary,
            pageURLString: res.pageURL.absoluteString,
            source: res.source,
            imageData: capturedThumb,
            articleImageURLString: res.articleImageURL?.absoluteString,
            articleImageData: res.articleImageData,
            latitude: res.coordinates?.latitude,
            longitude: res.coordinates?.longitude,
            inceptionYear: res.inceptionYear,
            wikidataType: res.wikidataType,
            onDeviceMatchScore: res.onDeviceMatchScore
        )
        context.insert(lookup)
        return lookup
    }

    /// Backfill an empty summary for legacy rows saved before the REST
    /// summary fallback existed. No-op unless `summary` is empty and the
    /// source is Wikipedia (NPS doesn't exhibit the empty-intro failure
    /// mode). Reuses a stored `rawSummary` when present, otherwise fetches
    /// the REST extract, then polishes. Shared by the history row (runs on
    /// appear) and the detail view (safety net) so the logic lives once.
    ///
    /// Guarded on `summary`, not `rawSummary`, because earlier versions of
    /// this fix populated only `rawSummary`; those rows still need their
    /// list-row summary filled in and should reuse the stored extract
    /// instead of re-fetching.
    @MainActor
    func backfillSummaryIfNeeded() async {
        guard summary.isEmpty, source == "wikipedia" else { return }
        let text: String
        if !rawSummary.isEmpty {
            text = rawSummary
        } else if let fetched = await wikipediaRESTSummaryExtract(for: resolvedTitle) {
            rawSummary = fetched
            text = fetched
        } else {
            return
        }
        summary = text
        let polished = await polishSummary(text)
        if polished != text {
            summary = polished
        }
    }
}
