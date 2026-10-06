import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AgentToolImage: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
}

/// Turns a project resource into an image a model can view, within MCP client limits.
enum AgentImage {
    /// Base64 of this many bytes stays within the 5 MiB image limit common to MCP clients.
    static let maximumBytes = 3_932_160
    static let maximumEdge = 2048
    static let viewable: [String: String] = [
        UTType.png.identifier: "image/png",
        UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif",
        UTType.webP.identifier: "image/webp",
    ]

    struct Prepared {
        let image: AgentToolImage
        let width: Int
        let height: Int
        let converted: Bool
    }

    static func prepare(_ data: Data) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw AgentToolError("not_image", "The file is not a supported raster image.")
        }
        if let mimeType = viewable[type], data.count <= maximumBytes, max(width, height) <= maximumEdge {
            return Prepared(
                image: AgentToolImage(data: data, mimeType: mimeType),
                width: width,
                height: height,
                converted: false,
            )
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ] as CFDictionary) else {
            throw AgentToolError("not_image", "The image could not be decoded.")
        }
        for (type, quality) in [(UTType.png, 1.0), (UTType.jpeg, 0.85), (UTType.jpeg, 0.6)] {
            if let encoded = encode(image, type: type, quality: quality), encoded.count <= maximumBytes {
                return Prepared(
                    image: AgentToolImage(data: encoded, mimeType: viewable[type.identifier] ?? "image/png"),
                    width: image.width,
                    height: image.height,
                    converted: true,
                )
            }
        }
        throw AgentToolError("too_large", "The image is too large to return, even after downscaling.")
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
