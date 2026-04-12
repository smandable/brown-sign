//
//  AppleIntelligence.swift
//  BrownSign
//
//  On-device language model helpers backed by the FoundationModels
//  framework (iOS 26+). Three passes:
//
//    1. normalizeLandmarkName — clean up OCR'd sign text
//    2. polishSummary          — tighten a Wikipedia/NPS extract
//    3. judgeMatch             — 0–1 confidence that the candidate matches
//
//  All three gracefully fall back when Apple Intelligence is
//  unavailable (older hardware, AI disabled, model not downloaded).
//

import Foundation
import FoundationModels

private func isAppleIntelligenceAvailable() -> Bool {
    if case .available = SystemLanguageModel.default.availability {
        return true
    }
    return false
}

// MARK: - (a) Normalize OCR → clean landmark name

func normalizeLandmarkName(from rawOCR: String) async -> String {
    guard isAppleIntelligenceAvailable() else { return rawOCR }

    let instructions = """
        You extract clean landmark names from OCR'd roadside sign text. \
        Return only the name — no explanations, no quotes.
        """
    let prompt = """
        Extract the landmark name from this OCR text. Strip directions, \
        distances, dates, and generic suffixes unless they are part of the \
        official name. Respond with only the name.

        OCR: \(rawOCR)
        """

    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? rawOCR : text
    } catch {
        return rawOCR
    }
}

// MARK: - (b) Polish a long summary to 2–3 sentences

func polishSummary(_ summary: String) async -> String {
    guard isAppleIntelligenceAvailable(), !summary.isEmpty else { return summary }

    let instructions = """
        You rewrite encyclopedia summaries as 2–3 sentence descriptions \
        suitable for a small card. Preserve the key facts. No fluff, \
        no meta commentary.
        """
    let prompt = "Rewrite this summary in 2–3 sentences:\n\n\(summary)"

    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? summary : text
    } catch {
        return summary
    }
}

// MARK: - (c) On-device match confidence score

func judgeMatch(
    query: String,
    candidateTitle: String,
    candidateSummary: String
) async -> Double? {
    guard isAppleIntelligenceAvailable() else { return nil }

    // Plain-text response + regex parse of the first floating-point
    // number. Previously used @Generable / structured output, but
    // that consistently returned 0.0 on device — either the macro
    // wasn't populating the value or the model wasn't emitting
    // parseable structured output. Plain text is more reliable.
    let instructions = """
        You judge whether an encyclopedia entry actually describes a user's \
        landmark query. Reply with ONLY a single decimal number between 0 \
        and 1 — no words, no explanation, no units.
        """
    let prompt = """
        Query: "\(query)"
        Candidate title: \(candidateTitle)
        Candidate summary: \(candidateSummary)

        Output a single number from 0.0 (wrong landmark) to 1.0 (perfect \
        match). Consider whether the candidate's type, location, and \
        description actually align with the query intent.
        """

    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Pull the first decimal number from the response, tolerant of
        // any extra words the model might add.
        let pattern = #"-?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text),
              let value = Double(text[range]) else {
            return nil
        }
        return min(max(value, 0), 1)
    } catch {
        return nil
    }
}
