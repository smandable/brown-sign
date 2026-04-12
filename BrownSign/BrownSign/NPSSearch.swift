//
//  NPSSearch.swift
//  BrownSign
//
//  Two-endpoint National Park Service lookup. Tries /parks first
//  (national parks), then /places (NRHP historic places + NPS-managed
//  historic sites). All failures return nil.
//

import Foundation

struct NPSResult {
    let title: String
    let summary: String
    let pageURL: URL
    /// First image URL from the NPS response's `images` array, if any.
    let imageURL: URL?
}

func searchNPS(query: String) async -> NPSResult? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !npsAPIKey.hasPrefix("REPLACE_") && !npsAPIKey.isEmpty else { return nil }

    if let park = await fetchNPSPark(query: trimmed) {
        return park
    }
    return await fetchNPSPlace(query: trimmed)
}

// MARK: - Shared image decoding

private struct NPSImage: Decodable {
    let url: String?
}

private func firstValidImageURL(_ images: [NPSImage]?) -> URL? {
    guard let images else { return nil }
    for image in images {
        if let urlString = image.url, let url = URL(string: urlString) {
            return url
        }
    }
    return nil
}

// MARK: - /parks endpoint

private struct ParksResponse: Decodable {
    let data: [ParkItem]
}

private struct ParkItem: Decodable {
    let fullName: String?
    let description: String?
    let url: String?
    let images: [NPSImage]?
}

private func fetchNPSPark(query: String) async -> NPSResult? {
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://developer.nps.gov/api/v1/parks?q=\(encoded)&limit=1&api_key=\(npsAPIKey)") else {
        return nil
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(ParksResponse.self, from: data)
        guard let first = decoded.data.first,
              let name = first.fullName, !name.isEmpty,
              let desc = first.description,
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
    } catch {
        return nil
    }
}

// MARK: - /places endpoint (NRHP + NPS historic places)

private struct PlacesResponse: Decodable {
    let data: [PlaceItem]
}

private struct PlaceItem: Decodable {
    let title: String?
    let listingDescription: String?
    let url: String?
    let images: [NPSImage]?
}

private func fetchNPSPlace(query: String) async -> NPSResult? {
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://developer.nps.gov/api/v1/places?q=\(encoded)&limit=1&api_key=\(npsAPIKey)") else {
        return nil
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(PlacesResponse.self, from: data)
        guard let first = decoded.data.first,
              let name = first.title, !name.isEmpty,
              let desc = first.listingDescription,
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
    } catch {
        return nil
    }
}
