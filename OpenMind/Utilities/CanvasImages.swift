import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// Max pixel dimension stored for an imported image. Larger photos are
/// thumbnailed with ImageIO before hitting SwiftData.
enum CanvasImages {
    static let maxPixelDimension: CGFloat = 2048
    /// Largest side (world points) of a newly created image item.
    static let maxWorldSide: CGFloat = 360
    static let minWorldSide: CGFloat = 60
}

/// Decodes a platform image from stored bytes. Nil when data is missing
/// or is not an image.
func makePlatformImage(from data: Data?) -> PlatformImage? {
    guard let data, !data.isEmpty else { return nil }
#if os(macOS)
    return NSImage(data: data)
#else
    return UIImage(data: data)
#endif
}

/// Pixel size of the image without decoding the full bitmap, via ImageIO.
func imagePixelSize(from data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
          let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
          w > 0, h > 0
    else { return nil }
    return CGSize(width: w, height: h)
}

/// In-memory image resources (decoded bitmap + pixel dimensions) so
/// frequently evaluated view bodies never re-decode the same bytes on every
/// selection change.
///
/// Keyed by item ID plus a data fingerprint (byte count + leading bytes), so
/// replacing the image bytes while keeping the ID invalidates the entry.
/// Source `Data` stays the authoritative persisted content; the cache only
/// holds derived render resources. Bounded via `NSCache` (count + cost caps,
/// auto-eviction under pressure) so boards with many large images never
/// retain every bitmap indefinitely. `NSCache` is thread-safe; a benign race
/// only repeats one decode. Negative results (unreadable bytes) are cached
/// too so corrupt images don't re-decode in every body evaluation.
enum ImageResourceCache {
    /// Leading bytes compared for fingerprinting. O(1) per lookup.
    private static let prefixLength = 256

    private static let imageCache: NSCache<NSString, ImageEntry> = {
        let c = NSCache<NSString, ImageEntry>()
        c.countLimit = 100
        c.totalCostLimit = 150 * 1024 * 1024
        return c
    }()
    private static let sizeCache: NSCache<NSString, SizeEntry> = {
        let c = NSCache<NSString, SizeEntry>()
        c.countLimit = 1000
        return c
    }()

    private final class ImageEntry: NSObject {
        /// Nil image is a cached negative (unreadable bytes).
        let image: PlatformImage?
        let length: Int
        let prefix: Data
        init(image: PlatformImage?, length: Int, prefix: Data) {
            self.image = image
            self.length = length
            self.prefix = prefix
        }
        func matches(_ data: Data) -> Bool {
            data.count == length && data.prefix(prefix.count) == prefix
        }
    }

    private final class SizeEntry: NSObject {
        /// Nil size is a cached negative (unreadable bytes).
        let size: CGSize?
        let length: Int
        let prefix: Data
        init(size: CGSize?, length: Int, prefix: Data) {
            self.size = size
            self.length = length
            self.prefix = prefix
        }
        func matches(_ data: Data) -> Bool {
            data.count == length && data.prefix(prefix.count) == prefix
        }
    }

    private static func fingerprint(_ data: Data) -> (length: Int, prefix: Data) {
        (data.count, data.prefix(prefixLength))
    }

    private static func key(_ id: UUID) -> NSString {
        id.uuidString as NSString
    }

    /// Cached decode (nil for missing/unreadable). Computes once per image.
    static func platformImage(forItem id: UUID, data: Data?) -> PlatformImage? {
        guard let data, !data.isEmpty else { return nil }
        let k = key(id)
        if let hit = imageCache.object(forKey: k), hit.matches(data) {
            return hit.image
        }
        let image = makePlatformImage(from: data)
        let (length, prefix) = fingerprint(data)
        imageCache.setObject(ImageEntry(image: image, length: length, prefix: prefix),
                             forKey: k, cost: data.count)
        return image
    }

    /// Cached pixel dimensions (nil for unreadable). Computes once per image.
    static func pixelSize(forItem id: UUID, data: Data) -> CGSize? {
        guard !data.isEmpty else { return nil }
        let k = key(id)
        if let hit = sizeCache.object(forKey: k), hit.matches(data) {
            return hit.size
        }
        let size = imagePixelSize(from: data)
        let (length, prefix) = fingerprint(data)
        sizeCache.setObject(SizeEntry(size: size, length: length, prefix: prefix), forKey: k)
        return size
    }

    /// Pre-populates dimensions already known at import so the first display
    /// never touches ImageIO in a view body.
    static func storePixelSize(_ size: CGSize?, forItem id: UUID, data: Data) {
        guard !data.isEmpty else { return }
        let (length, prefix) = fingerprint(data)
        sizeCache.setObject(SizeEntry(size: size, length: length, prefix: prefix), forKey: key(id))
    }

    /// Drops derived resources for `id` (call when the image bytes are
    /// replaced; stale fingerprints also self-invalidate on mismatch).
    static func invalidate(forItem id: UUID) {
        let k = key(id)
        imageCache.removeObject(forKey: k)
        sizeCache.removeObject(forKey: k)
    }
}

/// True when ImageIO recognises the bytes as an image.
func isImageData(_ data: Data) -> Bool {
    guard !data.isEmpty,
          let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return false }
    return CGImageSourceGetCount(source) > 0
}

/// Reads an image file with security-scoped access when needed (pasteboard
/// and drag-and-drop file URLs). Nil when unreadable or not an image.
func imageDataFromFileURL(_ url: URL) -> Data? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url), isImageData(data) else { return nil }
    return data
}

#if os(macOS)
/// Image bytes currently on the system clipboard (screenshots, Finder
/// copies, browser copies). File URLs first so originals (incl. GIFs)
/// survive; then raw bitmap types. Empty when the clipboard holds no image.
func clipboardImageDatas() -> [Data] {
    let pb = NSPasteboard.general
    // Finder / file copies: keep every readable image (preserves GIFs).
    if let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
        let files = urls.compactMap(imageDataFromFileURL)
        if !files.isEmpty { return files }
    }
    // Raw bitmaps: GIF first to preserve animation, then PNG/TIFF/JPEG.
    for id in [UTType.gif.identifier, UTType.png.identifier,
               UTType.tiff.identifier, UTType.jpeg.identifier] {
        let t = NSPasteboard.PasteboardType(id)
        if let data = pb.data(forType: t), isImageData(data) {
            return [data]
        }
    }
    return []
}
#else
/// Image bytes currently on the system clipboard. File URLs first
/// (Files app, preserves originals), GIF data before UIImage conversion
/// so animation survives, then one entry per copied UIImage.
func clipboardImageDatas() -> [Data] {
    let pb = UIPasteboard.general
    if pb.hasURLs, let urls = pb.urls, !urls.isEmpty {
        let files = urls.compactMap { $0.isFileURL ? imageDataFromFileURL($0) : nil }
        if !files.isEmpty { return files }
    }
    // Raw GIF first: `images` would flatten animation to a still.
    if let gif = pb.data(forPasteboardType: UTType.gif.identifier),
       isImageData(gif) {
        return [gif]
    }
    if pb.hasImages, let images = pb.images, !images.isEmpty {
        let datas = images.compactMap { img -> Data? in
            if let png = img.pngData(), isImageData(png) { return png }
            if let jpg = img.jpegData(compressionQuality: 0.9), isImageData(jpg) { return jpg }
            return nil
        }
        if !datas.isEmpty { return datas }
    }
    for id in [UTType.png.identifier, UTType.jpeg.identifier,
               UTType.tiff.identifier, UTType.heic.identifier] {
        if let data = pb.data(forPasteboardType: id), isImageData(data) {
            return [data]
        }
    }
    return []
}
#endif

/// Downscales large photos to `maxDimension` px (longest side) using
/// ImageIO thumbnails. Returns the original bytes when already small.
/// Preserves transparency: PNG-with-alpha stays PNG, otherwise JPEG q0.85.
func downscaledImageData(from data: Data, maxDimension: CGFloat = CanvasImages.maxPixelDimension) -> Data? {
    guard !data.isEmpty else { return nil }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0
    else { return nil }

    // Fast path: already small enough.
    if let size = imagePixelSize(from: data),
       max(size.width, size.height) <= maxDimension {
        return data
    }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }

    let hasAlpha: Bool = {
        let info = thumb.alphaInfo
        return info != .none && info != .noneSkipFirst && info != .noneSkipLast
    }()
    // Keep PNG only when we need the alpha channel; JPEG is much smaller.
    let sourceType = CGImageSourceGetType(source) as String?
    let usePNG = hasAlpha && (sourceType?.contains("png") == true || sourceType == nil)

    let destType: CFString = (usePNG ? UTType.png : UTType.jpeg).identifier as CFString
    guard let destData = CFDataCreateMutable(nil, 0),
          let dest = CGImageDestinationCreateWithData(destData, destType, 1, nil)
    else { return nil }
    let destProps: [CFString: Any] = usePNG
        ? [:]
        : [kCGImageDestinationLossyCompressionQuality: 0.85]
    CGImageDestinationAddImage(dest, thumb, destProps as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return destData as Data
}

/// World-space size for a new image item: aspect-fit inside `maxSide`,
/// never smaller than `minSide` on the short edge.
func fittedWorldSize(for pixelSize: CGSize,
                     maxSide: CGFloat = CanvasImages.maxWorldSide,
                     minSide: CGFloat = CanvasImages.minWorldSide) -> CGSize {
    guard pixelSize.width > 0, pixelSize.height > 0 else {
        return ItemKind.image.defaultSize
    }
    let longest = max(pixelSize.width, pixelSize.height)
    let scale = min(1, maxSide / longest) * 1.0
    // Keep the on-canvas size in world points proportional to pixels,
    // capped so a 4000px photo doesn't cover the whole board.
    var w = max(minSide, pixelSize.width * scale)
    var h = max(minSide, pixelSize.height * scale)
    // If one side clamped to minSide, rescale the other to keep aspect.
    if w == minSide, h == minSide {
        // Square-ish tiny source: leave square.
    } else if pixelSize.width < pixelSize.height, w == minSide {
        h = minSide * (pixelSize.height / pixelSize.width)
    } else if pixelSize.height < pixelSize.width, h == minSide {
        w = minSide * (pixelSize.width / pixelSize.height)
    }
    // Final guard: never exceed maxSide on either axis.
    let over = max(w / maxSide, h / maxSide, 1)
    w /= over
    h /= over
    return CGSize(width: w, height: h)
}
