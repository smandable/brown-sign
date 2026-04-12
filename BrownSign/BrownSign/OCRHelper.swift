//
//  OCRHelper.swift
//  BrownSign
//
//  Thin async wrapper around Vision's VNRecognizeTextRequest.
//

import Foundation
import UIKit
import Vision

/// Returns the ordered list of recognized text lines from a UIImage.
/// Each element is the top candidate string for one `VNRecognizedTextObservation`,
/// with empty strings filtered out. Preserves vertical order so the
/// downstream normalizer can distinguish "Wadsworth Mansion" (line 1)
/// from "2 mi" (line 2) on a multi-line brown sign.
func recognizeText(from image: UIImage) async -> [String] {
    guard let cgImage = image.cgImage else { return [] }

    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                // Sort top-to-bottom by boundingBox.maxY descending
                // (Vision's coordinate origin is bottom-left).
                let ordered = observations.sorted { a, b in
                    a.boundingBox.maxY > b.boundingBox.maxY
                }
                let lines = ordered
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
