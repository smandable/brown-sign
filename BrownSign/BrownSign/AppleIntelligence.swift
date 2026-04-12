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

/// Preferred entry point: takes the structured list of lines from
/// Vision OCR and asks Apple Intelligence to pull out the landmark
/// name, ignoring directions/distances/dates on separate lines.
func normalizeLandmarkName(fromLines lines: [String]) async -> String {
    let fallback = lines.joined(separator: " ")
    guard isAppleIntelligenceAvailable() else { return fallback }
    guard !lines.isEmpty else { return fallback }

    let instructions = """
        You extract clean landmark names from the lines of text on \
        brown roadside landmark signs. Return only the name — no \
        explanations, no quotes, no extra punctuation.
        """
    // Number the lines so the model can reference them in its reasoning
    // even though we only want the final name back.
    let numbered = lines.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")
    let prompt = """
        These are the text lines read from a brown roadside sign in \
        top-to-bottom order:

        \(numbered)

        Identify the landmark being pointed to. Ignore lines that are \
        just directions ("EXIT 5", "→ 2 MI"), distances, dates, or \
        generic labels ("HISTORIC SITE", "STATE PARK") unless those \
        words are part of the official name. Respond with only the \
        landmark name.
        """

    do {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    } catch {
        return fallback
    }
}

/// Legacy string-based convenience — splits on newlines and delegates
/// to the lines-based function. Kept so nothing breaks if a caller
/// still passes a pre-joined OCR string.
func normalizeLandmarkName(from rawOCR: String) async -> String {
    let lines = rawOCR
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return await normalizeLandmarkName(fromLines: lines)
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
