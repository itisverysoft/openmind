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
