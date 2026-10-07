import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit

    public typealias PlatformFont = NSFont
    public typealias PlatformColor = NSColor
    public typealias PlatformImage = NSImage
    public typealias PlatformView = NSView
    public typealias StorageEditActions = NSTextStorageEditActions

    /// The per-platform half of an attachment view (the only view shim).
    final class BoxView: NSView {
        let label: String
        init(label: String, size: CGSize) {
            self.label = label
            super.init(frame: CGRect(origin: .zero, size: size))
            setAccessibilityElement(true)
            setAccessibilityLabel(label)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override var isFlipped: Bool {
            true
        }

        override func draw(_: NSRect) {
            if let context = currentContext() {
                ChipDrawing.draw(label, in: bounds, context: context)
            }
        }
    }

    func currentContext() -> CGContext? {
        NSGraphicsContext.current?.cgContext
    }

    func renderImage(size: CGSize, draw: @escaping (CGContext) -> Void) -> PlatformImage {
        NSImage(size: size, flipped: true) { _ in
            if let context = currentContext() {
                draw(context)
            }
            return true
        }
    }
#else
    import UIKit

    public typealias PlatformFont = UIFont
    public typealias PlatformColor = UIColor
    public typealias PlatformImage = UIImage
    public typealias PlatformView = UIView
    public typealias StorageEditActions = NSTextStorage.EditActions

    final class BoxView: UIView {
        let label: String
        init(label: String, size: CGSize) {
            self.label = label
            super.init(frame: CGRect(origin: .zero, size: size))
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityLabel = label
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        override func draw(_: CGRect) {
            if let context = currentContext() {
                ChipDrawing.draw(label, in: bounds, context: context)
            }
        }
    }

    func currentContext() -> CGContext? {
        UIGraphicsGetCurrentContext()
    }

    func renderImage(size: CGSize, draw: @escaping (CGContext) -> Void) -> PlatformImage {
        UIGraphicsImageRenderer(size: size).image { draw($0.cgContext) }
    }
#endif

/// The only per-platform drawing helpers the visual layer needs.
enum ChipDrawing {
    static var font: PlatformFont {
        .systemFont(ofSize: 12, weight: .medium)
    }

    static let padding: CGFloat = 6

    static func width(of label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width) + padding * 2
    }

    static func draw(_ label: String, in rect: CGRect, context: CGContext) {
        context.saveGState()
        let path = CGPath(
            roundedRect: rect.insetBy(dx: 1, dy: 2),
            cornerWidth: 5,
            cornerHeight: 5,
            transform: nil,
        )
        context.addPath(path)
        context.setFillColor(PlatformColor.systemBlue.withAlphaComponent(0.14).cgColor)
        context.fillPath()
        context.restoreGState()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PlatformColor.systemBlue]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: CGPoint(x: rect.minX + padding, y: rect.midY - size.height / 2),
            withAttributes: attributes,
        )
    }
}
