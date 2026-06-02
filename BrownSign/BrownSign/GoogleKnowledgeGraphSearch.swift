//
//  GoogleKnowledgeGraphSearch.swift
//  BrownSign
//
//  Queries Google's Knowledge Graph Search API for an external
//  confidence score on a resolved landmark title. Short-circuits if
//  the API key is missing.
//

import Foundation

private struct KGResponse: Decodable {
    let itemListElement: [KGItem]?
}

private struct KGItem: Decodable {
    let resultScore: Double?
}

func fetchGoogleKGConfidence(for title: String) async -> Double? {
    // Guard on placeholder or empty key.
    guard !googleKnowledgeGraphAPIKey.hasPrefix("REPLACE_"),
          !googleKnowledgeGraphAPIKey.isEmpty else {
        return nil
    }

    guard let encodedQuery = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let encodedKey = googleKnowledgeGraphAPIKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://kgsearch.googleapis.com/v1/entities:search?query=\(encodedQuery)&limit=1&indent=False&key=\(encodedKey)") else {
        return nil
    }

    guard let data = await httpDataWithRetry(apiRequest(url)) else { return nil }
    guard let decoded = try? JSONDecoder().decode(KGResponse.self, from: data) else { return nil }
    return decoded.itemListElement?.first?.resultScore
}
