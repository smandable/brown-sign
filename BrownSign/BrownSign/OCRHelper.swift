//
//  OCRHelper.swift
//  BrownSign
//
//  Thin async wrapper around Vision's text recognition.
//

import Foundation
import UIKit
import Vision

/// Returns the ordered list of recognized text lines from a UIImage.
/// Each element is the top candidate string for one observation, with
/// empty strings filtered out. Preserves vertical order so the
/// downstream normalizer can distinguish "Wadsworth Mansion" (line 1)
/// from "2 mi" (line 2) on a multi-line brown sign.
///
/// Uses the Swift-native `RecognizeTextRequest` (iOS 18+) — its
/// `perform(on:)` is async and runs off the main actor internally, so
/// no manual `DispatchQueue` hop or completion-handler bridging is
/// needed the way the old `VNRecognizeTextRequest` required.
func recognizeText(from image: UIImage) async -> [String] {
    guard let cgImage = image.cgImage else { return [] }

    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    do {
        let observations = try await request.perform(on: cgImage)
        // Sort top-to-bottom. Vision's normalized rects use a
        // bottom-left origin, so a larger maxY sits higher on the image.
        let ordered = observations.sorted {
            $0.boundingBox.cgRect.maxY > $1.boundingBox.cgRect.maxY
        }
        return ordered
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    } catch {
        return []
    }
}
