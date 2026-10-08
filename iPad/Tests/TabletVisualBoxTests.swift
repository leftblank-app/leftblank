import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Testing
import UIKit

/// UIKit hosts attachment views only for attachments in the text storage
/// (iOS 27), so on the iPad the visual layer's boxes are images drawn by the
/// text view, and chips are tapped through it.
@MainActor
struct TabletVisualBoxTests {
    private let source = "#let item(id, s) = [#id #s]\n\nBefore #item(\"A1\", \"todo\") after.\n\n- list\n\nEnd\n"

    @Test func boxesAreImagesDrawnByTheTextView() async throws {
        let (editor, window) = try await makeEditor()
        defer { window.isHidden = true }
        let manager = try #require(editor.textLayoutManager)
        let text = source as NSString
        for (offset, label) in [(text.range(of: "#item(\"A1\"").location, "A1"),
                                (text.range(of: "- list").location, "•")]
        {
            let box = try #require(attachment(at: offset, in: manager))
            #expect(box.label.hasPrefix(label))
            #expect(!box.allowsTextAttachmentView)
            let location = try #require(TextKit2Geometry.location(offset, in: manager))
            let image = try #require(box.image(
                for: box.bounds, attributes: [:], location: location, textContainer: manager.textContainer,
            ))
            #expect(image.size == box.bounds.size)
            let pixels = try #require(image.cgImage.flatMap(MathBitmap.init))
            #expect(pixels.inkRows.isEmpty == false, "\(label) is drawn, not UIKit's placeholder")
        }
    }

    @Test func aTapOnAChipFindsItUnlessTheCaretShowsItsSource() async throws {
        let (editor, window) = try await makeEditor()
        defer { window.isHidden = true }
        let manager = try #require(editor.textLayoutManager)
        let call = (source as NSString).range(of: "#item(\"A1\", \"todo\")")
        let box = NSRange(location: NSMaxRange(call) - 1, length: 1)
        let frame = try #require(TextKit2Geometry.segments(box, type: .standard, in: manager).first)
        let point = CGPoint(
            x: frame.midX + editor.textContainerInset.left,
            y: frame.midY + editor.textContainerInset.top,
        )
        let (chip, rect) = try #require(editor.chip(at: point))
        #expect(chip.range == call)
        #expect(rect.contains(point))
        #expect(editor.chip(at: CGPoint(x: point.x, y: point.y + 200)) == nil)
        editor.selectedRange = NSRange(location: call.location + 3, length: 0)
        editor.session?.selectionDidChange(editor.selectedRange)
        await editor.session?.settled()
        #expect(editor.chip(at: point) == nil, "The caret in a call shows its source")
    }

    private func makeEditor() async throws -> (TabletTextView, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let editor = TabletTextView(usingTextLayoutManager: true)
        editor.frame = window.bounds
        window.rootViewController?.view.addSubview(editor)
        let style = TabletTheme.visualStyle(17)
        editor.installVisualLayer(style: style)
        editor.text = source
        editor.textStorage.setAttributes(
            style.baseAttributes,
            range: NSRange(location: 0, length: editor.textStorage.length),
        )
        editor.selectedRange = NSRange(location: (source as NSString).length, length: 0)
        editor.session?.open(selection: editor.selectedRange)
        await editor.session?.settled()
        window.layoutIfNeeded()
        return (editor, window)
    }

    private func attachment(at offset: Int, in manager: NSTextLayoutManager) -> VisualAttachment? {
        guard let location = TextKit2Geometry.location(offset, in: manager),
              let paragraph = manager.textLayoutFragment(for: location)?.textElement as? NSTextParagraph,
              let start = paragraph.elementRange?.location
        else {
            return nil
        }
        return VisualAttachment.box(
            in: paragraph.attributedString,
            at: offset - TextKit2Geometry.offset(of: start, in: manager),
        )
    }
}
