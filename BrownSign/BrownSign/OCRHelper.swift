//
//  OCRHelper.swift
//  BrownSign
//
//  Thin async wrapper around Vision's VNRecognizeTextRequest.
//

import Foundation
import UIKit
import Vision

func recognizeText(from image: UIImage) async -> String {
    guard let cgImage = image.cgImage else { return "" }

    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: " "))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
