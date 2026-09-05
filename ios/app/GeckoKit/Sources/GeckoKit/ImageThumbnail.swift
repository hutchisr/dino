import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
        guard box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else {
            return .zero
        }
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else {
            return box
        }
        let scale = min(box.width / source.width, box.height / source.height)
        guard scale.isFinite, scale > 0 else { return box }

        let width = (source.width * scale).rounded()
        let height = (source.height * scale).rounded()
        guard width.isFinite, height.isFinite else { return box }
        return CGSize(width: min(box.width, max(1, width)),
                      height: min(box.height, max(1, height)))
    }

    private static let animationFormatCache = NSCache<NSString, NSString>()
    private static let sizeCache = NSCache<NSString, SizeBox>()

    /// Display dimensions read without a full decode: raster image headers or
    /// the root SVG viewport/viewBox. Cheap enough to call synchronously while
    /// a row lays out. EXIF orientation is honoured (portrait photos store
    /// landscape pixels + a rotate tag). Cached; a `.zero` sentinel records
    /// "no dimensions" to avoid re-reading bad files. Foundation + ImageIO
    /// only, so the host `swift test` build exercises it.
    public static func pixelSize(path: String) -> CGSize? {
        let k = "size:\(path)" as NSString
        if let v = sizeCache.object(forKey: k) {
            return v.size == .zero ? nil : v.size
        }

        let size: CGSize?
        if MediaFileKind.isSVG(fileName: path) {
            size = svgPixelSize(path: path)
        } else {
            size = rasterPixelSize(path: path) ?? svgPixelSize(path: path)
        }
        sizeCache.setObject(SizeBox(size ?? .zero), forKey: k)
        return size
    }

    private static func rasterPixelSize(path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path) as CFURL
        let opt = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url, opt),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else {
            return nil
        }
        // Orientations 5–8 are the 90°-rotated cases: swap to get display size.
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func svgPixelSize(path: String) -> CGSize? {
        guard let attributes = svgRootAttributes(path: path) else { return nil }
        if let width = svgLength(attributes["width"]),
           let height = svgLength(attributes["height"]) {
            return CGSize(width: width, height: height)
        }
        guard let viewBox = attributes["viewBox"] else { return nil }
        let values = viewBox
            .split { $0 == "," || $0.isWhitespace }
            .compactMap { Double($0) }
        guard values.count == 4,
              values.allSatisfy(\.isFinite),
              values[2] > 0,
              values[3] > 0 else {
            return nil
        }
        return CGSize(width: values[2], height: values[3])
    }

    static func isSVG(path: String) -> Bool {
        MediaFileKind.isSVG(fileName: path)
            || svgRootAttributes(path: path) != nil
    }

    static func validatedSVGText(_ data: Data) -> String? {
        guard let source = String(data: data, encoding: .utf8),
              source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              source.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            return nil
        }
        return source
    }

    private static func svgRootAttributes(path: String) -> [String: String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 64 * 1024) ?? Data()
        } catch {
            return nil
        }
        guard !prefix.isEmpty, validatedSVGText(prefix) != nil else { return nil }

        let root = SVGRootElementParser()
        let parser = XMLParser(data: prefix)
        parser.delegate = root
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return root.attributes
    }

    private static func svgLength(_ raw: String?) -> CGFloat? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        let scale: Double
        if value.hasSuffix("px") {
            value.removeLast(2)
            scale = 1
        } else if value.hasSuffix("pt") {
            value.removeLast(2)
            scale = 96 / 72
        } else if value.hasSuffix("pc") {
            value.removeLast(2)
            scale = 16
        } else if value.hasSuffix("in") {
            value.removeLast(2)
            scale = 96
        } else if value.hasSuffix("cm") {
            value.removeLast(2)
            scale = 96 / 2.54
        } else if value.hasSuffix("mm") {
            value.removeLast(2)
            scale = 96 / 25.4
        } else if value.hasSuffix("q") {
            value.removeLast()
            scale = 96 / 101.6
        } else {
            scale = 1
        }
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              number.isFinite,
              number > 0 else {
            return nil
        }
        let pixels = number * scale
        guard pixels.isFinite else { return nil }
        return CGFloat(pixels)
    }

    /// Returns the display format only for a multi-frame GIF or WebP. Like
    /// `pixelSize`, this reads image metadata without decoding frame pixels.
    static func animatedFormat(path: String) -> String? {
        let key = "animation:\(path)" as NSString
        if let cached = animationFormatCache.object(forKey: key) {
            return cached.length == 0 ? nil : cached as String
        }

        let url = URL(fileURLWithPath: path) as CFURL
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, options),
              CGImageSourceGetCount(source) > 1,
              let sourceType = CGImageSourceGetType(source) else {
            animationFormatCache.setObject("", forKey: key)
            return nil
        }

        let typeIdentifier = sourceType as String
        let format: String?
        if typeIdentifier == UTType.gif.identifier {
            format = "GIF"
        } else if typeIdentifier == UTType.webP.identifier {
            format = "WEBP"
        } else {
            format = nil
        }
        animationFormatCache.setObject((format ?? "") as NSString, forKey: key)
        return format
    }
}

/// NSCache stores class references only, and `NSValue(cgSize:)` is iOS-only —
/// this box is what lets the size cache compile on the macOS host build too.
private final class SizeBox {
    let size: CGSize
    init(_ size: CGSize) { self.size = size }
}

private final class SVGRootElementParser: NSObject, XMLParserDelegate {
    private(set) var attributes: [String: String]?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "svg" {
            attributes = attributeDict
        }
        parser.abortParsing()
    }
}

#if canImport(UIKit)
import UIKit
import AVFoundation
import WebKit

/// Why the cache exists: a chat row's SwiftUI body re-evaluates constantly while
/// scrolling, and decoding a full-resolution photo from disk on each pass
/// (`UIImage(contentsOfFile:)` in `body`) is what made multi-image scrolling
/// choppy — it re-reads and re-decodes megapixels every frame, per visible
/// image. Here the decode happens once, off the main thread, downsampled to the
/// preview size, and the result is cached; subsequent renders are a cache hit.
///
/// UIKit/AVFoundation/WebKit-only, so excluded from the host `swift test`
/// build (the iOS Simulator run exercises it).
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

    /// Several animated rows can be visible at once, so each inline preview gets
    /// a tighter decoded-frame budget than the single full-screen viewer.
    private static let inlineAnimatedImageDecodedByteLimit = 24 * 1024 * 1024
    private static let viewerAnimatedImageDecodedByteLimit = 64 * 1024 * 1024
    private static let defaultFrameDuration: TimeInterval = 0.1

    private static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(path)@\(maxPixel)" as NSString
    }

    private static func videoKey(_ path: String, _ maxPixel: Int) -> NSString {
        "video:\(path)@\(maxPixel)" as NSString
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
        if isSVG(path: path) {
            return await loadSVGThumbnail(path: path, maxPixel: maxPixel)
        }
        let operation = ImageDecodeOperation(path: path, maxPixel: maxPixel)
        return await withTaskCancellationHandler {
            await operation.value(on: imageDecodeQueue)
        } onCancel: {
            operation.cancel()
        }
    }

    /// Animated GIF or WebP frames for an inline chat row. This deliberately
    /// returns nil for static images so the caller can keep its cached thumbnail.
    static func loadInlineAnimatedImageAsync(path: String, maxPixel: Int) async -> UIImage? {
        if Task.isCancelled { return nil }
        let operation = ImageDecodeOperation(path: path, maxPixel: maxPixel, mode: .inlineAnimation)
        return await withTaskCancellationHandler {
            await operation.value(on: imageDecodeQueue)
        } onCancel: {
            operation.cancel()
        }
    }

    /// Full-screen decode. GIF and WebP sources retain all animation frames;
    /// every other source uses the same cached static thumbnail path as before.
    static func loadViewerImageAsync(path: String, maxPixel: Int) async -> UIImage? {
        if Task.isCancelled { return nil }
        if isSVG(path: path) {
            return await loadSVGThumbnail(path: path, maxPixel: maxPixel)
        }
        let operation = ImageDecodeOperation(path: path, maxPixel: maxPixel, mode: .viewer)
        return await withTaskCancellationHandler {
            await operation.value(on: imageDecodeQueue)
        } onCancel: {
            operation.cancel()
        }
    }

    private static func loadSVGThumbnail(path: String, maxPixel: Int) async -> UIImage? {
        guard maxPixel > 0, !Task.isCancelled else { return nil }
        let k = key(path, maxPixel)
        if let cached = cache.object(forKey: k) { return cached }

        let sourceSize = pixelSize(path: path)
            ?? CGSize(width: maxPixel, height: maxPixel)
        let targetSize = fit(
            sourceSize,
            in: CGSize(width: maxPixel, height: maxPixel)
        )
        let html = await Task.detached(priority: .userInitiated) {
            svgImageDocument(path: path)
        }.value
        guard let html, !Task.isCancelled else { return nil }
        guard let image = await SVGSnapshotRenderer.render(
            html: html,
            pixelSize: targetSize
        ), !Task.isCancelled else {
            return nil
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: k, cost: cost)
        return image
    }

    private static func svgImageDocument(path: String) -> String? {
        let byteLimit = 8 * 1024 * 1024
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data: Data
        do {
            data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        } catch {
            return nil
        }
        guard !data.isEmpty,
              data.count <= byteLimit,
              validatedSVGText(data) != nil else {
            return nil
        }
        let encoded = data.base64EncodedString()
        return """
            <!doctype html>
            <html>
            <head>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <meta http-equiv="Content-Security-Policy"
                    content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
              <style>
                html, body {
                  background: transparent;
                  height: 100%;
                  margin: 0;
                  overflow: hidden;
                  width: 100%;
                }
                img {
                  display: block;
                  height: 100%;
                  object-fit: contain;
                  width: 100%;
                }
              </style>
            </head>
            <body><img alt="" src="data:image/svg+xml;base64,\(encoded)"></body>
            </html>
            """
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

    fileprivate static func loadInlineAnimatedImage(
        path: String,
        maxPixel: Int,
        isCancelled: () -> Bool
    ) -> UIImage? {
        loadAnimatedImage(
            path: path,
            maxPixel: maxPixel,
            decodedByteLimit: inlineAnimatedImageDecodedByteLimit,
            isCancelled: isCancelled
        )
    }

    fileprivate static func loadViewerImage(
        path: String,
        maxPixel: Int,
        isCancelled: () -> Bool
    ) -> UIImage? {
        if let animated = loadAnimatedImage(
            path: path,
            maxPixel: maxPixel,
            decodedByteLimit: viewerAnimatedImageDecodedByteLimit,
            isCancelled: isCancelled
        ) {
            return animated
        }
        guard !isCancelled() else { return nil }
        return loadThumbnail(path: path, maxPixel: maxPixel)
    }

    private static func loadAnimatedImage(
        path: String,
        maxPixel: Int,
        decodedByteLimit: Int,
        isCancelled: () -> Bool
    ) -> UIImage? {
        guard maxPixel > 0, decodedByteLimit > 0 else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, sourceOptions),
              let sourceType = CGImageSourceGetType(source) else {
            return nil
        }
        let typeIdentifier = sourceType as String
        guard typeIdentifier == UTType.gif.identifier ||
                typeIdentifier == UTType.webP.identifier else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return nil }
        let decodedBytesPerFrame = max(1, decodedByteLimit / frameCount)
        let memoryBoundMaxPixel = Int((Double(decodedBytesPerFrame) / 4).squareRoot())
        let frameMaxPixel = max(1, min(maxPixel, memoryBoundMaxPixel))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: frameMaxPixel,
        ] as CFDictionary

        var frames: [UIImage] = []
        frames.reserveCapacity(frameCount)
        var duration: TimeInterval = 0
        for index in 0..<frameCount {
            if isCancelled() { return nil }
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                return nil
            }
            frames.append(UIImage(cgImage: frame))
            duration += frameDuration(
                source: source,
                index: index,
                typeIdentifier: typeIdentifier
            )
        }
        guard duration.isFinite, duration > 0 else { return nil }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func frameDuration(
        source: CGImageSource,
        index: Int,
        typeIdentifier: String
    ) -> TimeInterval {
        let dictionaryKey: CFString
        let unclampedDelayKey: CFString
        let delayKey: CFString
        if typeIdentifier == UTType.gif.identifier {
            dictionaryKey = kCGImagePropertyGIFDictionary
            unclampedDelayKey = kCGImagePropertyGIFUnclampedDelayTime
            delayKey = kCGImagePropertyGIFDelayTime
        } else {
            dictionaryKey = kCGImagePropertyWebPDictionary
            unclampedDelayKey = kCGImagePropertyWebPUnclampedDelayTime
            delayKey = kCGImagePropertyWebPDelayTime
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let animationProperties = properties[dictionaryKey] as? [CFString: Any] else {
            return defaultFrameDuration
        }
        let duration = (animationProperties[unclampedDelayKey] as? NSNumber)?.doubleValue
            ?? (animationProperties[delayKey] as? NSNumber)?.doubleValue
            ?? defaultFrameDuration
        return duration.isFinite && duration > 0 ? duration : defaultFrameDuration
    }
}

@MainActor
private final class SVGSnapshotRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didAllowInitialNavigation = false

    private init(pixelSize: CGSize) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let scale = max(webView.traitCollection.displayScale, 1)
        webView.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(1, pixelSize.width / scale),
                height: max(1, pixelSize.height / scale)
            )
        )
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
    }

    static func render(html: String, pixelSize: CGSize) async -> UIImage? {
        let renderer = SVGSnapshotRenderer(pixelSize: pixelSize)
        return await renderer.render(html: html)
    }

    private func render(html: String) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    finish(nil)
                    return
                }
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(nil)
                }
                webView.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isInitialDocument = !didAllowInitialNavigation
            && navigationAction.navigationType == .other
            && (url == nil || url?.scheme == "about")
        if isInitialDocument {
            didAllowInitialNavigation = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil else { return }
        webView.layoutIfNeeded()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { [weak self] image, error in
            self?.finish(error == nil ? image : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        continuation.resume(returning: image)
    }
}

private final class ImageDecodeOperation: Operation, @unchecked Sendable {
    enum Mode {
        case thumbnail
        case inlineAnimation
        case viewer
    }

    private let path: String
    private let maxPixel: Int
    private let mode: Mode
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var completed = false

    init(path: String, maxPixel: Int, mode: Mode = .thumbnail) {
        self.path = path
        self.maxPixel = maxPixel
        self.mode = mode
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
        let image: UIImage?
        switch mode {
        case .thumbnail:
            image = ThumbnailLoader.loadThumbnail(path: path, maxPixel: maxPixel)
        case .inlineAnimation:
            image = ThumbnailLoader.loadInlineAnimatedImage(
                path: path,
                maxPixel: maxPixel,
                isCancelled: { self.isCancelled }
            )
        case .viewer:
            image = ThumbnailLoader.loadViewerImage(
                path: path,
                maxPixel: maxPixel,
                isCancelled: { self.isCancelled }
            )
        }
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
