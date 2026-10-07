import CoreGraphics
import Foundation
import VisualPresentation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// TextKit 1 visual layer, one implementation for NSTextView and UITextView.
///
/// Concealed characters keep their storage but get `.null` glyphs (zero
/// advance, nothing drawn). A replacement's first character becomes a control
/// glyph with `.whitespace` action whose width is the box width; the rest of
/// its range is null. Taller boxes (math, images) grow their line fragment.
/// The backing string, undo, copy and IME are untouched.
public final class ConcealingLayoutManager: NSLayoutManager {
    public private(set) var plan = DisplayPlan()
    /// Box heights above the line height (rendered math, images).
    public var replacementHeight: (Replacement) -> CGFloat = { replacement in
        switch replacement.content {
        case let .fragment(_, size, _): size.height
        case .image: 48
        default: 0
        }
    }

    private let handler = Handler()

    override public init() {
        super.init()
        handler.owner = self
        delegate = handler
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// Applies a new plan and invalidates only characters whose display changed.
    /// Returns the invalidated character ranges.
    @discardableResult
    public func apply(_ next: DisplayPlan) -> [NSRange] {
        let changed = next.changedRanges(from: plan)
        plan = next
        let length = textStorage?.length ?? 0
        for range in changed {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clipped.length > 0 else {
                continue
            }
            invalidateGlyphs(forCharacterRange: clipped, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: clipped, actualCharacterRange: nil)
        }
        return changed
    }

    func width(of replacement: Replacement) -> CGFloat {
        switch replacement.content {
        case let .chip(chip): ChipDrawing.width(of: chip.label)
        case .bullet: 12
        case .image: 64
        case let .fragment(_, size, _): size.width
        }
    }

    override public func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let context = currentContext(), let container = textContainers.first else {
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for replacement in plan.replacements(in: characters) {
            let glyph = glyphIndexForCharacter(at: replacement.range.location)
            var rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.y = line.minY
            rect.size.height = line.height
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch replacement.content {
            case let .chip(chip):
                ChipDrawing.draw(chip.label, in: rect, context: context)
            case .bullet:
                ChipDrawing.draw("•", in: rect, context: context)
            case let .image(path):
                ChipDrawing.draw((path as NSString).lastPathComponent, in: rect, context: context)
            case .fragment:
                // Production draws the cached engine image here; the spike draws its box.
                context.setStrokeColor(PlatformColor.systemGreen.cgColor)
                context.stroke(rect.insetBy(dx: 1, dy: 1))
            }
        }
    }

    final class Handler: NSObject, NSLayoutManagerDelegate {
        weak var owner: ConcealingLayoutManager?

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font aFont: PlatformFont,
            forGlyphRange glyphRange: NSRange,
        ) -> Int {
            guard let plan = owner?.plan, !(plan.conceals.isEmpty && plan.replacements.isEmpty) else {
                return 0
            }
            var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
            var changed = false
            for index in 0 ..< glyphRange.length {
                let character = charIndexes[index]
                properties[index] = props[index]
                if let replacement = plan.replacement(containing: character) {
                    properties[index] = character == replacement.range.location ? .controlCharacter : .null
                    changed = true
                } else if plan.isConcealed(character) {
                    properties[index].insert(.null)
                    changed = true
                }
            }
            guard changed else {
                return 0
            }
            layoutManager.setGlyphs(
                glyphs,
                properties: properties,
                characterIndexes: charIndexes,
                font: aFont,
                forGlyphRange: glyphRange,
            )
            return glyphRange.length
        }

        func layoutManager(
            _: NSLayoutManager,
            shouldUse action: NSLayoutManager.ControlCharacterAction,
            forControlCharacterAt charIndex: Int,
        ) -> NSLayoutManager.ControlCharacterAction {
            if let replacement = owner?.plan.replacement(containing: charIndex),
               replacement.range.location == charIndex
            {
                return .whitespace
            }
            return action
        }

        func layoutManager(
            _: NSLayoutManager,
            boundingBoxForControlGlyphAt _: Int,
            for _: NSTextContainer,
            proposedLineFragment proposedRect: CGRect,
            glyphPosition: CGPoint,
            characterIndex charIndex: Int,
        ) -> CGRect {
            guard let owner, let replacement = owner.plan.replacement(containing: charIndex) else {
                return .zero
            }
            return CGRect(
                x: glyphPosition.x,
                y: 0,
                width: owner.width(of: replacement),
                height: max(proposedRect.height, owner.replacementHeight(replacement)),
            )
        }

        // swiftlint:disable:next function_parameter_count
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in _: NSTextContainer,
            forGlyphRange glyphRange: NSRange,
        ) -> Bool {
            guard let owner, !owner.plan.replacements.isEmpty else {
                return false
            }
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var extra: CGFloat = 0
            for replacement in owner.plan.replacements(in: characters)
                where NSLocationInRange(replacement.range.location, characters)
            {
                extra = max(extra, owner.replacementHeight(replacement) - lineFragmentRect.pointee.height)
            }
            guard extra > 0 else {
                return false
            }
            lineFragmentRect.pointee.size.height += extra
            lineFragmentUsedRect.pointee.size.height += extra
            baselineOffset.pointee += extra
            return true
        }
    }
}
