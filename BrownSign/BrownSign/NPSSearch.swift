//
//  NPSSearch.swift
//  BrownSign
//
//  Two-endpoint National Park Service lookup. Tries /parks first
//  (national parks), then /places (NRHP historic places + NPS-managed
//  historic sites). All failures return nil.
//

import Foundation

nonisolated struct NPSResult {
    let title: String
    let summary: String
    let pageURL: URL
    /// First image URL from the NPS response's `images` array, if any.
    let imageURL: URL?
}

nonisolated func searchNPS(query: String) async -> NPSResult? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !npsAPIKey.hasPrefix("REPLACE_") && !npsAPIKey.isEmpty else { return nil }

    if let park = await fetchNPSPark(query: trimmed) {
        return park
    }
    return await fetchNPSPlace(query: trimmed)
}

// MARK: - Shared image decoding

nonisolated private struct NPSImage: Decodable {
    let url: String?
}

nonisolated private func firstValidImageURL(_ images: [NPSImage]?) -> URL? {
    guard let images else { return nil }
    for image in images {
        if let urlString = image.url, let url = URL(string: urlString) {
            return url
        }
    }
    return nil
}

// MARK: - /parks endpoint

nonisolated private struct ParksResponse: Decodable {
    let data: [ParkItem]
}

nonisolated private struct ParkItem: Decodable {
    let fullName: String?
    let description: String?
    let url: String?
    let images: [NPSImage]?
}

nonisolated private func fetchNPSPark(query: String) async -> NPSResult? {
    // URLComponents-built (an "&" in the query can't truncate the value) and
    // the key rides in the X-Api-Key header, not the URL — URLs are the most
    // logged part of a request, and URLSession's on-disk cache keys entries
    // by the full URL, key included.
    guard let url = apiURL("https://developer.nps.gov/api/v1/parks", [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "limit", value: "1"),
    ]) else {
        return nil
    }

    guard let data = await httpDataWithRetry(apiRequest(url, headers: ["X-Api-Key": npsAPIKey])) else { return nil }
    guard let decoded = try? JSONDecoder().decode(ParksResponse.self, from: data),
          let first = decoded.data.first,
          let name = first.fullName, !name.isEmpty,
          let desc = first.description, !desc.isEmpty,
          let urlString = first.url,
          let pageURL = URL(string: urlString) else {
        return nil
    }
    return NPSResult(
        title: name,
        summary: desc,
        pageURL: pageURL,
        imageURL: firstValidImageURL(first.images)
    )
}

// MARK: - /places endpoint (NRHP + NPS historic places)

nonisolated private struct PlacesResponse: Decodable {
    let data: [PlaceItem]
}

nonisolated private struct PlaceItem: Decodable {
    let title: String?
    let listingDescription: String?
    let url: String?
    let images: [NPSImage]?
}

nonisolated private func fetchNPSPlace(query: String) async -> NPSResult? {
    // Same URLComponents + X-Api-Key treatment as /parks above.
    guard let url = apiURL("https://developer.nps.gov/api/v1/places", [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "limit", value: "1"),
    ]) else {
        return nil
    }

    guard let data = await httpDataWithRetry(apiRequest(url, headers: ["X-Api-Key": npsAPIKey])) else { return nil }
    guard let decoded = try? JSONDecoder().decode(PlacesResponse.self, from: data),
          let first = decoded.data.first,
          let name = first.title, !name.isEmpty,
          let urlString = first.url,
          let pageURL = URL(string: urlString) else {
        return nil
    }
    // Many entries in the /places dataset have an empty or absent
    // listingDescription but are still valid historic places with a title,
    // url, and image. Fall back to a generic blurb so a title-only match
    // still resolves to a card instead of dropping the result entirely.
    let listing = first.listingDescription ?? ""
    let summary = listing.isEmpty
        ? "A historic place documented by the National Park Service."
        : listing
    return NPSResult(
        title: name,
        summary: summary,
        pageURL: pageURL,
        imageURL: firstValidImageURL(first.images)
    )
}
