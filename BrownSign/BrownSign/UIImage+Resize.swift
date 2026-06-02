//
//  UIImage+Resize.swift
//  BrownSign
//
//  Thumbnail-scaling helpers shared between the scan flow (history-row
//  thumbnails, captured-photo downscale) and landmark image hydration
//  (downsizing remote article images before persisting them in SwiftData).
//

#if canImport(UIKit)
import UIKit

extension UIImage {
    /// Redraw at exactly `size`. Caller is responsible for picking a
    /// size that preserves aspect ratio if that matters.
    ///
    /// `format.scale = 1` so `size` means *pixels*, not points. Without
    /// it `UIGraphicsImageRenderer` defaults to the device screen scale
    /// (2x–3x), so a "800px" downscale would silently produce a
    /// 1600–2400px image — inflating OCR input and the persisted
    /// SwiftData thumbnails by ~4–9x. `draw(in:)` still bakes in the
    /// source's `imageOrientation`, so the result is upright regardless.
    func resized(to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Scale so the longest edge equals `maxDimension`, preserving
    /// aspect ratio. Returns `self` unchanged when the image is already
    /// smaller — callers don't have to guard.
    func resized(toMaxDimension maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
        return resized(to: newSize)
    }
}
#endif
