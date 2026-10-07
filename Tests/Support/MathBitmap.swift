import CoreGraphics

/// The pixels of a rendered equation, for checking ink positions and colour.
public struct MathBitmap {
    public struct Color: Equatable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
        public let alpha: UInt8
    }

    public let width: Int
    public let height: Int
    private let pixels: [UInt8]

    public init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.pixels = pixels
    }

    /// Opacity at a column and a row counted from the top.
    public func alpha(_ column: Int, _ row: Int) -> UInt8 {
        pixels[(row * width + column) * 4 + 3]
    }

    private func inked(_ row: Int) -> Int {
        (0 ..< width).count { alpha($0, row) > 127 }
    }

    /// Bands of rows containing ink, as pixel edges from the top.
    public var inkRows: [(top: Double, bottom: Double)] {
        var bands: [(top: Double, bottom: Double)] = [], start: Int?
        for row in 0 ... height {
            let ink = row < height && inked(row) > 0
            if ink, start == nil {
                start = row
            } else if !ink, let top = start {
                bands.append((Double(top), Double(row)))
                start = nil
            }
        }
        return bands
    }

    /// The centre of the rows inked across most of the width (a fraction bar), in pixels from the top.
    public var widestRow: Double? {
        let rows = (0 ..< height).filter { inked($0) >= width * 7 / 10 }
        guard let first = rows.first, let last = rows.last else {
            return nil
        }
        return Double(first + last + 1) / 2
    }

    /// The colour of the most opaque pixel, un-premultiplied.
    public var inkColor: Color {
        var best = 0
        for index in 0 ..< width * height where pixels[index * 4 + 3] > pixels[best * 4 + 3] {
            best = index
        }
        let alpha = Double(max(pixels[best * 4 + 3], 1))
        func channel(_ offset: Int) -> UInt8 {
            UInt8(min(255, (Double(pixels[best * 4 + offset]) * 255 / alpha).rounded()))
        }
        return Color(red: channel(0), green: channel(1), blue: channel(2), alpha: pixels[best * 4 + 3])
    }
}
