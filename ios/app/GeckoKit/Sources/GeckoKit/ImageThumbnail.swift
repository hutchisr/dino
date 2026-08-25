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
import AVFoundation

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

    private static let imageDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "me.anemoneya.gecko.thumbnail-decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(path)@\(maxPixel)" as NSString
    }

    private static func videoKey(_ path: String, _ maxPixel: Int) -> NSString {
        "video:\(path)@\(maxPixel)" as NSString
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

    static func cachedVideoThumbnail(path: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: videoKey(path, maxPixel))
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

    /// Cancellation-aware and concurrency-bounded entry point for scrolling
    /// views. Queued work is removed when SwiftUI cancels the view task; an
    /// already-running ImageIO decode finishes in one of only two worker slots.
    static func loadThumbnailAsync(path: String, maxPixel: Int) async -> UIImage? {
        if Task.isCancelled { return nil }
        if let cached = cachedThumbnail(path: path, maxPixel: maxPixel) {
            return cached
        }
        let operation = ThumbnailDecodeOperation(path: path, maxPixel: maxPixel)
        return await withTaskCancellationHandler {
            await operation.value(on: imageDecodeQueue)
        } onCancel: {
            operation.cancel()
        }
    }

    static func loadVideoThumbnail(path: String, maxPixel: Int) async -> UIImage? {
        let k = videoKey(path, maxPixel)
        if let cached = cache.object(forKey: k) { return cached }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        let cg = await withTaskCancellationHandler {
            await generateVideoImage(generator: generator, at: time)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        guard let cg else { return nil }
        let image = UIImage(cgImage: cg)
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: k, cost: cost)
        return image
    }

    private static func generateVideoImage(generator: AVAssetImageGenerator, at time: CMTime) async -> CGImage? {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                continuation.resume(returning: error == nil ? image : nil)
            }
        }
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

private final class ThumbnailDecodeOperation: Operation, @unchecked Sendable {
    private let path: String
    private let maxPixel: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var completed = false

    init(path: String, maxPixel: Int) {
        self.path = path
        self.maxPixel = maxPixel
    }

    func value(on queue: OperationQueue) async -> UIImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            let shouldEnqueue = !isCancelled
            lock.unlock()

            if shouldEnqueue {
                queue.addOperation(self)
            } else {
                finish(nil)
            }
        }
    }

    override func main() {
        guard !isCancelled else {
            finish(nil)
            return
        }
        let image = ThumbnailLoader.loadThumbnail(path: path, maxPixel: maxPixel)
        finish(isCancelled ? nil : image)
    }

    override func cancel() {
        super.cancel()
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}
#endif
