//
//  LandmarkArtwork.swift
//  BrownSign
//
//  Landmark images outside SwiftUI: CarPlay list thumbnails and the Now
//  Playing artwork. Same sources as LandmarkThumbnail (persisted bytes,
//  else the article image URL) and the same placeholder, the brown
//  signpost tile.
//

import UIKit

@MainActor
enum LandmarkArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    /// The landmark's image with its longest edge at most `maxPixels`,
    /// or nil when it has none or the download fails.
    static func image(for item: NarrationItem, maxPixels: CGFloat) async -> UIImage? {
        let key = "\(item.id)|\(Int(maxPixels))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let data: Data?
        if let bytes = item.imageData {
            data = bytes
        } else if let url = item.imageURL {
            data = await httpDataWithRetry(apiRequest(url), maxAttempts: 2)
        } else {
            data = nil
        }
        guard let data else { return nil }
        let image = await Task.detached(priority: .utility) {
            UIImage.downsampled(from: data, maxDimension: maxPixels)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// A square, corner-rounded thumbnail for a CarPlay list row.
    static func rowThumbnail(for item: NarrationItem, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard let source = await image(for: item, maxPixels: max(size.width, size.height) * scale * 2) else {
            return nil
        }
        return render(size: size, scale: scale) { rect in
            let fill = max(rect.width / source.size.width, rect.height / source.size.height)
            let drawn = CGSize(width: source.size.width * fill, height: source.size.height * fill)
            source.draw(in: CGRect(
                x: (rect.width - drawn.width) / 2,
                y: (rect.height - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
    }

    /// LandmarkThumbnail's placeholder: the signpost in plain BrandBrown on
    /// a BrandBrownForeground ground, brown-on-brown like a real roadside
    /// sign. Light and dark variants, since CarPlay switches with the car.
    static func placeholder(size: CGSize, scale: CGFloat) -> UIImage {
        tile(
            size: size,
            scale: scale,
            fill: UIColor(named: "BrandBrownForeground") ?? .brown,
            glyph: "signpost.right.fill",
            glyphColor: UIColor(named: "BrandBrown") ?? .brown
        )
    }

    /// A green action tile (Play nearby, Narrate as I drive): a white
    /// glyph on the app's action green.
    static func actionTile(systemName: String, size: CGSize, scale: CGFloat) -> UIImage {
        tile(
            size: size,
            scale: scale,
            fill: UIColor(named: "AccentButton") ?? .systemGreen,
            glyph: systemName,
            glyphColor: .white
        )
    }

    private static func tile(
        size: CGSize,
        scale: CGFloat,
        fill: UIColor,
        glyph: String,
        glyphColor: UIColor
    ) -> UIImage {
        let key = "tile|\(glyph)|\(Int(size.width))x\(Int(size.height))@\(scale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style).modifyingTraits { $0.displayScale = scale }
            let fillColor = fill.resolvedColor(with: traits)
            let glyphTint = glyphColor.resolvedColor(with: traits)
            let image = render(size: size, scale: scale) { rect in
                fillColor.setFill()
                UIRectFill(rect)
                let config = UIImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .semibold)
                guard let symbol = UIImage(systemName: glyph, withConfiguration: config)?
                    .withTintColor(glyphTint, renderingMode: .alwaysOriginal) else { return }
                let s = symbol.size
                symbol.draw(in: CGRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            asset.register(image, with: traits)
        }
        let image = asset.image(with: UITraitCollection.current)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Draws into a `size`-point canvas at `scale`, clipped to the app's
    /// thumbnail rounding (10pt on a 56pt tile, the same proportion).
    private static func render(size: CGSize, scale: CGFloat, draw: (CGRect) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: size.width * 10 / 56).addClip()
            draw(rect)
        }
    }
}
