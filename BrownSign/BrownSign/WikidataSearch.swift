//
//  WikidataSearch.swift
//  BrownSign
//
//  Wikidata enrichment — pulls structured coordinates, inception year,
//  and instance-of type for a resolved landmark. Free, no auth.
//

import Foundation

struct WikidataEnrichment {
    let coordinate: Coordinate?
    let inceptionYear: Int?
    let typeLabel: String?
}

/// Looks up the Wikidata entity that corresponds to the exact given
/// Wikipedia article title (via the `sites=enwiki&titles=…` lookup).
/// This is far more reliable than fuzzy `wbsearchentities`, which
/// returns label matches and can land on the wrong entity entirely
/// (e.g. a band called "Wadsworth Mansion" instead of the building).
func fetchWikidataEnrichment(for wikipediaTitle: String) async -> WikidataEnrichment? {
    guard let claims = await fetchWikidataClaimsByWikipediaTitle(wikipediaTitle) else {
        return nil
    }

    let coordinate = parseCoordinate(from: claims)
    let inceptionYear = parseInceptionYear(from: claims)
    let typeQID = parseInstanceOfQID(from: claims)

    var typeLabel: String?
    if let qid = typeQID {
        typeLabel = await fetchWikidataLabel(for: qid)
    }

    // Only return something if we got at least one useful field.
    if coordinate == nil && inceptionYear == nil && typeLabel == nil {
        return nil
    }
    return WikidataEnrichment(
        coordinate: coordinate,
        inceptionYear: inceptionYear,
        typeLabel: typeLabel
    )
}

// MARK: - Step 1: fetch claims by exact Wikipedia title (sitelink lookup)

private func fetchWikidataClaimsByWikipediaTitle(_ title: String) async -> [String: Any]? {
    guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&sites=enwiki&titles=\(encoded)&format=json&props=claims&normalize=1") else {
        return nil
    }

    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: Any] else {
            return nil
        }
        // entities is keyed by QID on success, or "-1" on miss.
        // Grab any value whose key isn't "-1" and has claims.
        for (key, value) in entities {
            guard key != "-1",
                  let entity = value as? [String: Any],
                  let claims = entity["claims"] as? [String: Any] else {
                continue
            }
            return claims
        }
        return nil
    } catch {
        return nil
    }
}

// MARK: - Claim parsers

/// Digs `claims.P625[0].mainsnak.datavalue.value` for `latitude`/`longitude`.
private func parseCoordinate(from claims: [String: Any]) -> Coordinate? {
    guard let list = claims["P625"] as? [[String: Any]],
          let first = list.first,
          let mainsnak = first["mainsnak"] as? [String: Any],
          let datavalue = mainsnak["datavalue"] as? [String: Any],
          let value = datavalue["value"] as? [String: Any],
          let lat = value["latitude"] as? Double,
          let lon = value["longitude"] as? Double else {
        return nil
    }
    return Coordinate(latitude: lat, longitude: lon)
}

/// Digs `claims.P571[0].mainsnak.datavalue.value.time` (e.g. "+1934-07-01T00:00:00Z").
private func parseInceptionYear(from claims: [String: Any]) -> Int? {
    guard let list = claims["P571"] as? [[String: Any]],
          let first = list.first,
          let mainsnak = first["mainsnak"] as? [String: Any],
          let datavalue = mainsnak["datavalue"] as? [String: Any],
          let value = datavalue["value"] as? [String: Any],
          let time = value["time"] as? String else {
        return nil
    }
    // Expected shape: "+1934-07-01T00:00:00Z"
    let trimmed = time.hasPrefix("+") || time.hasPrefix("-")
        ? String(time.dropFirst())
        : time
    let yearPart = trimmed.prefix(4)
    return Int(yearPart)
}

/// Digs `claims.P31[0].mainsnak.datavalue.value.id` (e.g. "Q33506").
private func parseInstanceOfQID(from claims: [String: Any]) -> String? {
    guard let list = claims["P31"] as? [[String: Any]],
          let first = list.first,
          let mainsnak = first["mainsnak"] as? [String: Any],
          let datavalue = mainsnak["datavalue"] as? [String: Any],
          let value = datavalue["value"] as? [String: Any],
          let id = value["id"] as? String else {
        return nil
    }
    return id
}

// MARK: - Step 3: resolve a QID to an English label

private func fetchWikidataLabel(for qid: String) async -> String? {
    guard let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(qid)&format=json&props=labels&languages=en") else {
        return nil
    }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: Any],
              let entity = entities[qid] as? [String: Any],
              let labels = entity["labels"] as? [String: Any],
              let en = labels["en"] as? [String: Any],
              let value = en["value"] as? String else {
            return nil
        }
        return value
    } catch {
        return nil
    }
}
