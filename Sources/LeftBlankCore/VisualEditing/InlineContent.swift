import CoreGraphics
import Foundation
import ImageIO
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// A decoded inline image and the size the editor shows it at.
public struct InlineImage: @unchecked Sendable {
    public let image: CGImage
    public let size: CGSize
}

/// Decodes `#image` files off the main thread, bounded in pixels and points,
/// and caches them by path and modification date.
@MainActor
public final class InlineImageCache {
    struct Key: Hashable {
        let url: URL
        let modified: Date?
    }

    /// Largest size shown, in points; larger images scale down.
    public nonisolated static let maximumSize = CGSize(width: 480, height: 360)
    static let limit = 64
    private var images: [Key: InlineImage?] = [:]
    private var order: [Key] = []
    private var loading: Set<Key> = []
    /// Called on the main thread when an image finishes decoding.
    public var loaded: ((URL) -> Void)?

    public init() {}

    /// The cached image, or nil while it decodes or when it cannot be read.
    public func image(at url: URL) -> InlineImage? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = Key(url: url, modified: modified)
        if let image = images[key] {
            return image
        }
        guard modified != nil, loading.insert(key).inserted else {
            return nil
        }
        Task {
            let image = await Task.detached(priority: .utility) { Self.decode(url) }.value
            loading.remove(key)
            images[key] = image
            order.append(key)
            while order.count > Self.limit {
                images[order.removeFirst()] = nil
            }
            loaded?(url)
        }
        return nil
    }

    public func removeAll() {
        images = [:]
        order = []
    }

    nonisolated static func decode(_ url: URL) -> InlineImage? {
        // Decode at most twice the largest shown size, for Retina displays.
        let maximum = max(maximumSize.width, maximumSize.height) * 2
        var image: CGImage?
        var natural = CGSize.zero
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        {
            natural = CGSize(width: width, height: height)
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
            ] as CFDictionary)
        }
        #if canImport(AppKit)
            // SVG and PDF figures, which ImageIO does not decode.
            if image == nil, let vector = NSImage(contentsOf: url), vector.size.width > 0, vector.size.height > 0 {
                natural = vector.size
                let fit = min(2, maximum / max(vector.size.width, vector.size.height))
                var rect = CGRect(origin: .zero, size: CGSize(
                    width: vector.size.width * fit,
                    height: vector.size.height * fit,
                ))
                image = vector.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
        #endif
        guard let image, natural.width > 0, natural.height > 0 else {
            return nil
        }
        let fit = min(1, maximumSize.width / natural.width, maximumSize.height / natural.height)
        return InlineImage(image: image, size: CGSize(width: natural.width * fit, height: natural.height * fit))
    }
}
