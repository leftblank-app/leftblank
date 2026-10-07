import CoreGraphics
import Foundation
import VisualPresentation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// TextKit 2 visual layer, shared verbatim by NSTextView and UITextView.
///
/// NSTextContentStorage asks its delegate for each paragraph's display
/// text. We return a paragraph with *the same UTF-16 length* as the source:
/// concealed units become U+200B (zero width), and a replacement's first unit
/// becomes U+FFFC carrying an attachment (chip, image, math) while the rest
/// become U+200B. Locations therefore map 1:1 between source and display, so
/// TextKit 2's selection, hit testing and editing ranges remain source ranges.
/// The backing NSTextStorage (undo, copy, IME, save) never changes.
public final class DisplaySubstitution: NSObject, NSTextContentStorageDelegate {
    public enum Mode: Sendable {
        /// Same length: U+200B for concealed units, U+FFFC for boxes. The default.
        case zeroWidth
        /// Same length: keep characters, 0.01 pt clear font (today's hack, for comparison).
        case tinyFont
        /// Different length: delete concealed units (for comparison; breaks mapping).
        case shorter
    }

    public var mode: Mode
    public private(set) var plan = DisplayPlan()
    public private(set) var paragraphRequests = 0
    public weak var contentStorage: NSTextContentStorage?

    public init(mode: Mode = .zeroWidth) {
        self.mode = mode
    }

    /// Installs on a text view's content storage (no `layoutManager` access).
    public func install(on storage: NSTextContentStorage) {
        contentStorage = storage
        storage.delegate = self
    }

    /// Applies a plan and regenerates only paragraphs whose display changed.
    /// Returns the invalidated source ranges.
    @discardableResult
    public func apply(_ next: DisplayPlan, within windows: [NSRange]? = nil, force: [NSRange] = []) -> [NSRange] {
        let changed = (windows.map { $0.flatMap { next.changedRanges(from: plan, within: $0) } }
            ?? next.changedRanges(from: plan)) + force
        plan = next
        guard let storage = contentStorage, let text = storage.textStorage else {
            return changed
        }
        let length = text.length
        let paragraphs = Self.paragraphs(covering: changed, in: text.string as NSString)
        guard !paragraphs.isEmpty else {
            return changed
        }
        // An attribute-only edit makes NSTextContentStorage rebuild these
        // paragraphs (asking the delegate again). No characters change, so the
        // text view registers no undo and the selection stays.
        storage.performEditingTransaction {
            for range in paragraphs where NSMaxRange(range) <= length {
                text.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
        return changed
    }

    /// Updates the plan during a text-storage edit, when invalidating would
    /// nest editing transactions. The caller forces the affected ranges on
    /// the next `apply`.
    public func rebase(_ next: DisplayPlan) {
        plan = next
    }

    static func paragraphs(covering ranges: [NSRange], in source: NSString) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: source.length))
            guard clipped.length > 0 || range.location < source.length else {
                continue
            }
            let paragraph = source.paragraphRange(for: clipped)
            if let last = result.last, NSMaxRange(last) >= paragraph.location {
                result[result.count - 1] = NSUnionRange(last, paragraph)
            } else {
                result.append(paragraph)
            }
        }
        return result
    }

    public func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange,
    ) -> NSTextParagraph? {
        paragraphRequests += 1
        guard let text = textContentStorage.textStorage else {
            return nil
        }
        let hasConceal = DisplayPlan.overlaps(plan.conceals, range)
        let boxes = plan.replacements(in: range)
        guard hasConceal || !boxes.isEmpty else {
            return nil
        }
        let display = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        func local(_ source: NSRange) -> NSRange? {
            let clipped = NSIntersectionRange(source, range)
            return clipped
                .length > 0 ? NSRange(location: clipped.location - range.location, length: clipped.length) : nil
        }
        var deletions: [NSRange] = []
        for conceal in plan.conceals(in: range) {
            guard let span = local(conceal) else {
                continue
            }
            switch mode {
            case .zeroWidth:
                display.replaceCharacters(in: span, with: String(repeating: "\u{200B}", count: span.length))
            case .tinyFont:
                display.addAttributes([
                    .font: PlatformFont.systemFont(ofSize: 0.01),
                    .foregroundColor: PlatformColor.clear,
                ], range: span)
            case .shorter:
                deletions.append(span)
            }
        }
        for box in boxes {
            guard let span = local(box.range), box.range.location >= range.location else {
                continue
            }
            let attributes = display.attributes(at: span.location, effectiveRange: nil)
            let attachment = VisualAttachment(replacement: box, font: attributes[.font] as? PlatformFont)
            var boxAttributes = attributes
            boxAttributes[.attachment] = attachment
            let head = NSAttributedString(string: "\u{FFFC}", attributes: boxAttributes)
            if mode == .shorter {
                display.replaceCharacters(in: span, with: head)
                continue
            }
            let tail = NSAttributedString(
                string: String(repeating: "\u{200B}", count: span.length - 1),
                attributes: attributes,
            )
            let replacement = NSMutableAttributedString(attributedString: head)
            replacement.append(tail)
            display.replaceCharacters(in: span, with: replacement)
        }
        for span in deletions.sorted(by: { $0.location > $1.location }) {
            display.deleteCharacters(in: span)
        }
        return NSTextParagraph(attributedString: display)
    }
}

extension DisplayPlan {
    static func overlaps(_ ranges: [NSRange], _ range: NSRange) -> Bool {
        !conceals(ranges, in: range).isEmpty
    }

    static func conceals(_ ranges: [NSRange], in range: NSRange) -> ArraySlice<NSRange> {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var end = low
        while end < ranges.count, ranges[end].location < NSMaxRange(range) {
            end += 1
        }
        return ranges[low ..< end]
    }

    func conceals(in range: NSRange) -> ArraySlice<NSRange> {
        Self.conceals(conceals, in: range)
    }
}

/// An attachment that exists only in the display paragraph. TextKit 2 asks
/// it for a view provider; the box's identity is its source range.
public final class VisualAttachment: NSTextAttachment {
    public let replacement: Replacement
    let size: CGSize
    let baseline: CGFloat

    init(replacement: Replacement, font: PlatformFont?) {
        self.replacement = replacement
        let lineHeight = font.map { $0.ascender - $0.descender } ?? 17
        switch replacement.content {
        case let .chip(chip):
            size = CGSize(width: ChipDrawing.width(of: chip.label), height: lineHeight + 2)
            baseline = font.map { -$0.descender + 1 } ?? 4
        case .bullet:
            size = CGSize(width: 12, height: lineHeight)
            baseline = font.map { -$0.descender } ?? 4
        case .image:
            size = CGSize(width: 64, height: 48)
            baseline = 0
        case let .fragment(_, fragmentSize, fragmentBaseline):
            size = fragmentSize
            baseline = fragmentBaseline
        }
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: -baseline, width: size.width, height: size.height)
        allowsTextAttachmentView = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    public var label: String {
        switch replacement.content {
        case let .chip(chip): chip.label
        case .bullet: "•"
        case let .image(path): (path as NSString).lastPathComponent
        case let .fragment(key, _, _): key
        }
    }

    public nonisolated(unsafe) static var viewProviderRequests = 0

    override public func viewProvider(
        for parentView: PlatformView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
    ) -> NSTextAttachmentViewProvider? {
        Self.viewProviderRequests += 1
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
        let label = attachment.label, size = attachment.size
        view = MainActor.assumeIsolated { BoxView(label: label, size: size) }
    }
}
