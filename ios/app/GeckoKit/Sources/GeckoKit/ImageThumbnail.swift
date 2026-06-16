import Foundation
import CoreGraphics

/// Decoded, downsampled thumbnails for inline chat image previews, plus the
/// up-front sizing math that lets a row reserve its final height before the
/// image has decoded.
enum ThumbnailLoader {
    /// The size `source` becomes when scaled to fit inside `box` (aspect
    /// preserved), rounded to whole points. Used to reserve a row's final
    /// height before its image has decoded, so the row never grows when the
    /// decode lands and a chat pinned to the bottom stays pinned. Pure geometry,
    /// so it's exercised by the host `swift test` build.
    public static func fit(_ source: CGSize, in box: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return box }
        let scale = min(box.width / source.width, box.height / source.height)
        return CGSize(width: (source.width * scale).rounded(),
                      height: (source.height * scale).rounded())
    }
}

#if canImport(UIKit)
import UIKit
import ImageIO

/// Why the cache exists: a chat row's SwiftUI body re-evaluates constantly while
/// scrolling, and decoding a full-resolution photo from disk on each pass
/// (`UIImage(contentsOfFile:)` in `body`) is what made multi-image scrolling
/// choppy — it re-reads and re-decodes megapixels every frame, per visible
/// image. Here the decode happens once, off the main thread, downsampled to the
/// preview size, and the result is cached; subsequent renders are a cache hit.
///
/// UIKit/ImageIO-only, so excluded from the host `swift test` build (the iOS
/// Simulator run exercises it).
extension ThumbnailLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // Bound by decoded bytes, not count — a few large thumbnails shouldn't
        // sit alongside hundreds of small ones unbounded. ~80MB of previews is
        // plenty of look-ahead for scrolling; NSCache also evicts under memory
        // pressure on its own.
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()

    private static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(path)@\(maxPixel)" as NSString
    }

    /// Pixel dimensions of an image read from its header only — no full decode,
    /// so it's cheap enough to call synchronously while a row lays out. EXIF
    /// orientation is honoured (portrait photos store landscape pixels + a
    /// rotate tag), so the returned size is the displayed orientation. Cached;
    /// a `.zero` sentinel records "no dimensions" to avoid re-reading bad files.
    private static let sizeCache = NSCache<NSString, NSValue>()
    public static func pixelSize(path: String) -> CGSize? {
        let k = "size:\(path)" as NSString
        if let v = sizeCache.object(forKey: k) {
            let s = v.cgSizeValue
            return s == .zero ? nil : s
        }
        let url = URL(fileURLWithPath: path) as CFURL
        let opt = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url, opt),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else {
            sizeCache.setObject(NSValue(cgSize: .zero), forKey: k)
            return nil
        }
        // Orientations 5–8 are the 90°-rotated cases: swap to get display size.
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        sizeCache.setObject(NSValue(cgSize: size), forKey: k)
        return size
    }

    /// Cache-only lookup (no decode). Synchronous and cheap — use it to seed a
    /// view's initial state so an already-loaded image renders with no flash.
    static func cachedThumbnail(path: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(path, maxPixel))
    }

    /// Return a downsampled thumbnail no larger than `maxPixel` on its longest
    /// side, decoding and caching it on a miss. Call OFF the main thread — the
    /// decode is the expensive part. Returns nil if the file can't be read.
    static func loadThumbnail(path: String, maxPixel: Int) -> UIImage? {
        let k = key(path, maxPixel)
        if let cached = cache.object(forKey: k) { return cached }
        guard let image = downsample(path: path, maxPixel: maxPixel) else { return nil }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: k, cost: cost)
        return image
    }

    /// ImageIO downsample: decodes straight to a thumbnail at the target size
    /// rather than decoding full-res then shrinking, so peak memory and CPU stay
    /// proportional to the preview, not the source photo.
    private static func downsample(path: String, maxPixel: Int) -> UIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url, srcOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,         // decode now (off-main), not at draw
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return nil }
        return UIImage(cgImage: cg)
    }
}
#endif
