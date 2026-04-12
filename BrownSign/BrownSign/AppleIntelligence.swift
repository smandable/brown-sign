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

@Generable
struct MatchJudgment {
    @Guide(description: "Confidence between 0.0 and 1.0 that the candidate entry describes what the user queried")
    let confidence: Double
}

func judgeMatch(
    query: String,
    candidateTitle: String,
    candidateSummary: String
) async -> Double? {
    guard isAppleIntelligenceAvailable() else { return nil }

    let instructions = """
        You judge whether an encyclopedia entry actually describes a user's \
        landmark query. Be strict: a low score means the entry is about \
        something different, a high score means it's the correct landmark.
        """
    let prompt = """
        Query: "\(query)"
        Candidate title: \(candidateTitle)
        Candidate summary: \(candidateSummary)

        How confident are you (0.0–1.0) that this candidate describes what \
        the user was looking for?
        """

    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: MatchJudgment.self)
        let raw = response.content.confidence
        return min(max(raw, 0), 1)
    } catch {
        return nil
    }
}
