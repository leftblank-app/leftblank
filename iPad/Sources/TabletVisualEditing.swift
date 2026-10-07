import LeftBlankCore
import SwiftUI
import UIKit

/// The iPad half of the visual layer: the same `VisualEditorSession` as the
/// Mac, attached to this TextKit 2 `UITextView`.
extension TabletTextView {
    func installVisualLayer(style: VisualStyle) {
        guard let manager = textLayoutManager, let content = manager.textContentManager as? NSTextContentStorage else {
            return
        }
        let session = VisualEditorSession(contentStorage: content, textLayoutManager: manager, style: style)
        session.hasMarkedText = { [weak self] in self?.markedTextRange != nil }
        session.onActivateChip = { [weak self] chip, view in self?.showChipForm(chip, from: view) }
        session.viewport = (
            visible: { [weak self] in self?.containerVisibleRect() ?? .zero },
            scroll: { [weak self] in self?.scrollContainer(to: $0) },
        )
        self.session = session
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

    func showChipForm(_ chip: Chip, from view: UIView) {
        guard let session, let signature = session.signature(for: chip), isEditable, markedTextRange == nil,
              let workspace, workspace.canEditSource, !workspace.busy,
              var presenter = window?.rootViewController
        else {
            return
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        weak var host: UIViewController?
        let form = UIHostingController(rootView: ChipForm(
            chip: chip,
            signature: signature,
            formatter: session.formatter,
            apply: { [weak self] values in
                if let replacement = try self?.session?.edit(chip, values: values) {
                    self?.workspace?.apply(replacement)
                }
                host?.dismiss(animated: true)
            },
            cancel: { host?.dismiss(animated: true) },
        ))
        host = form
        form.modalPresentationStyle = .popover
        form.popoverPresentationController?.sourceView = view
        form.popoverPresentationController?.sourceRect = view.bounds
        form.preferredContentSize = form.sizeThatFits(in: CGSize(width: 340, height: 600))
        presenter.present(form, animated: true)
    }

    /// Inserts a copy of the previous chip's call with Tab placeholders.
    func repeatPreviousCall() async {
        guard let session, isEditable, markedTextRange == nil else {
            return
        }
        let location = selectedRange.location
        guard let insertion = await session.repeatPrevious(at: location), selectedRange.location == location,
              let workspace
        else {
            return
        }
        workspace.apply(TextReplacement(range: insertion.range, text: insertion.snippet.text))
        setSnippet(insertion.snippet, at: insertion.range.location)
    }
}
