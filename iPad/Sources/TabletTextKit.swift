import LeftBlankCore
import UIKit

/// The iPad half of the TextKit 2 editor: the same `SourceStyler` as the Mac,
/// attached to this `UITextView`, and geometry that never trusts TextKit 2's
/// estimates.
extension TabletTextView {
    func installStyler(fontSize: CGFloat) {
        guard let manager = textLayoutManager, let content = manager.textContentManager as? NSTextContentStorage else {
            return
        }
        let styler = SourceStyler(
            contentStorage: content,
            textLayoutManager: manager,
            fontSize: fontSize,
            textColor: TabletTheme.sourceText,
        )
        styler.hasMarkedText = { [weak self] in self?.markedTextRange != nil }
        styler.viewport = (
            visible: { [weak self] in self?.containerVisibleRect() ?? .zero },
            scroll: { [weak self] in self?.scrollContainer(to: $0) },
        )
        self.styler = styler
    }

    /// Scrolls `range` into view without changing the selection. UIKit's
    /// `scrollRangeToVisible` reads estimated TextKit 2 geometry and misses
    /// distant targets; see `TextKit2Geometry.reveal`.
    func reveal(_ range: NSRange) {
        guard let manager = textLayoutManager else {
            scrollRangeToVisible(range)
            return
        }
        TextKit2Geometry.revealByRelocating(
            range.location,
            in: manager,
            visible: containerVisibleRect,
            scroll: scrollContainer,
        )
    }

    /// Taps place the caret here. UIKit's own answer comes from estimated
    /// TextKit 2 geometry and can be 100,000 characters off after a jump.
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        let container = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        guard let manager = textLayoutManager,
              let offset = TextKit2Geometry.viewportInsertionOffset(at: container, in: manager)
        else {
            return super.closestPosition(to: point)
        }
        return position(from: beginningOfDocument, offset: offset)
    }

    func containerVisibleRect() -> CGRect {
        CGRect(origin: contentOffset, size: bounds.size)
            .offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top)
    }

    /// Scrolls so that container-y `y` is at the top of the viewport.
    func scrollContainer(to y: CGFloat) {
        setContentOffset(
            CGPoint(x: contentOffset.x, y: max(-adjustedContentInset.top, y + textContainerInset.top)),
            animated: false,
        )
    }
}
