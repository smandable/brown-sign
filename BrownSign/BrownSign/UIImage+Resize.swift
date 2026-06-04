//
//  UIImage+Resize.swift
//  BrownSign
//
//  Thumbnail-scaling helpers shared between the scan flow (history-row
//  thumbnails, captured-photo downscale) and landmark image hydration
//  (downsizing remote article images before persisting them in SwiftData).
//  Includes a Data-based ImageIO downsampler so a full-resolution camera
//  frame (up to 48MP) is decoded straight to its target size, never in full.
//

#if canImport(UIKit)
import ImageIO
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

    /// Decode `data` directly at a downsampled size with ImageIO, so a large
    /// (e.g. 48MP) photo is never fully decoded into memory just to shrink it.
    /// The result's longest edge is at most `maxDimension` px, with the source's
    /// EXIF orientation baked in so it comes out upright. Returns nil only when
    /// the data isn't a decodable image.
    static func downsampled(from data: Data, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
#endif
