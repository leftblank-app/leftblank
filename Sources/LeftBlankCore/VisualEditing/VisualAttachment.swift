import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// A box drawn in place of source: a chip, a list bullet, an image or a typeset
/// equation. It exists only in the display paragraph; the text storage keeps
/// the source, so copy, undo, find and accessibility see the markup.
public final class VisualAttachment: NSTextAttachment {
    public enum Content {
        case chip(String)
        case bullet
        case image(CGImage?, name: String)
        case math(CGImage)
    }

    public let content: Content
    let size: CGSize
    /// Distance from the bottom edge to the text baseline.
    let descent: CGFloat
    let style: VisualStyle
    weak var session: VisualEditorSession?

    init(content: Content, size: CGSize, descent: CGFloat, style: VisualStyle, session: VisualEditorSession?) {
        self.content = content
        self.size = size
        self.descent = descent
        self.style = style
        self.session = session
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: -descent, width: size.width, height: size.height)
        allowsTextAttachmentView = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// What assistive technology and tests read for the box.
    public var label: String {
        switch content {
        case let .chip(label): label
        case .bullet: "•"
        case let .image(_, name): name
        case .math: "equation"
        }
    }

    static let chipPadding: CGFloat = 6

    static func chipFont(_ style: VisualStyle) -> PlatformFont {
        .systemFont(ofSize: max(9, style.fontSize - 2), weight: .medium)
    }

    static func chip(_ label: String, style: VisualStyle, session: VisualEditorSession?) -> VisualAttachment {
        let font = style.font
        let width = ceil((label as NSString).size(withAttributes: [.font: chipFont(style)]).width) + chipPadding * 2
        return VisualAttachment(
            content: .chip(label),
            size: CGSize(width: width, height: ceil(font.ascender - font.descender) + 2),
            descent: -font.descender + 1,
            style: style,
            session: session,
        )
    }

    override public func viewProvider(
        for parentView: PlatformView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
    ) -> NSTextAttachmentViewProvider? {
        let provider = VisualAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location,
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class VisualAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? VisualAttachment else {
            return
        }
        // TextKit loads attachment views on the main thread.
        nonisolated(unsafe) let box = attachment, location = location
        nonisolated(unsafe) weak let manager = textLayoutManager
        view = MainActor.assumeIsolated {
            let view = VisualBoxView(attachment: box)
            view.activate = { [weak view] in
                guard let view, let manager else {
                    return
                }
                box.session?.activateChip(at: TextKit2Geometry.offset(of: location, in: manager), view: view)
            }
            return view
        }
    }
}

/// Draws one box. Only chips respond to the pointer: they open their form.
@MainActor
final class VisualBoxView: PlatformView {
    let attachment: VisualAttachment
    var activate: (() -> Void)?

    init(attachment: VisualAttachment) {
        self.attachment = attachment
        super.init(frame: CGRect(origin: .zero, size: attachment.size))
        #if canImport(AppKit)
            setAccessibilityElement(true)
            setAccessibilityLabel(attachment.label)
            setAccessibilityRole(isChip ? .button : .image)
        #else
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityLabel = attachment.label
            accessibilityTraits = isChip ? .button : .image
            isUserInteractionEnabled = isChip
            if isChip {
                addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            }
        #endif
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    private var isChip: Bool {
        if case .chip = attachment.content {
            return true
        }
        return false
    }

    #if canImport(AppKit)
        override var isFlipped: Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            isChip ? super.hitTest(point) : nil
        }

        override func mouseDown(with _: NSEvent) {
            activate?()
        }

        override func resetCursorRects() {
            if isChip {
                addCursorRect(bounds, cursor: .pointingHand)
            }
        }

        override func accessibilityPerformPress() -> Bool {
            activate?()
            return isChip
        }

        override func draw(_: NSRect) {
            paint(bounds)
        }
    #else
        @objc private func tapped() {
            activate?()
        }

        override func accessibilityActivate() -> Bool {
            activate?()
            return isChip
        }

        override func draw(_ rect: CGRect) {
            paint(bounds)
        }
    #endif

    private func paint(_ rect: CGRect) {
        let style = attachment.style
        switch attachment.content {
        case let .chip(label):
            let path = PlatformBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 2), radius: 5)
            style.chipFill.setFill()
            path.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: VisualAttachment.chipFont(style),
                .foregroundColor: style.chip,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(
                at: CGPoint(x: rect.minX + VisualAttachment.chipPadding, y: rect.midY - size.height / 2),
                withAttributes: attributes,
            )
        case .bullet:
            let attributes: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.marker]
            ("•" as NSString).draw(
                at: CGPoint(x: rect.minX, y: rect.maxY - attachment.descent - style.font.ascender),
                withAttributes: attributes,
            )
        case let .image(image, name):
            if let image {
                PlatformImage(cgImage: image, size: rect.size).draw(in: rect)
            } else {
                style.codeBackground.setFill()
                PlatformBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), radius: 4).fill()
                (name as NSString).draw(
                    in: rect.insetBy(dx: 6, dy: 6),
                    withAttributes: [.font: VisualAttachment.chipFont(style), .foregroundColor: style.marker],
                )
            }
        case let .math(image):
            PlatformImage(cgImage: image, size: rect.size).draw(in: rect)
        }
    }
}

#if canImport(AppKit)
    typealias PlatformImage = NSImage
    typealias PlatformBezierPath = NSBezierPath

    extension NSBezierPath {
        convenience init(roundedRect rect: CGRect, radius: CGFloat) {
            self.init(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
    }
#else
    typealias PlatformBezierPath = UIBezierPath

    final class PlatformImage {
        let image: UIImage
        init(cgImage: CGImage, size _: CGSize) {
            image = UIImage(cgImage: cgImage)
        }

        func draw(in rect: CGRect) {
            image.draw(in: rect)
        }
    }

    extension UIBezierPath {
        convenience init(roundedRect rect: CGRect, radius: CGFloat) {
            self.init(roundedRect: rect, cornerRadius: radius)
        }
    }
#endif
