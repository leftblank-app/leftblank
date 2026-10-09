import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import SwiftUI
import Testing
import UIKit

/// The production iPad editor styles source with fonts only, as the Mac does:
/// the laid-out text is the source, with no attachments.
@Suite(.serialized)
@MainActor
struct TabletStylingTests {
    @Test func theEditorStylesSourceWithFontsAndShowsEveryCharacter() async throws {
        let source = """
        #let item(id, title, s) = [#id #title #s]
        = Title
        == Section

        Text *strong* and _emph_ with `code`.
        #item("LB-001", "标题", "done")
        $φ = (1+√5)/2 ≈ 1.618$

        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("styling-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let subscription = TabletSubscription(service: SubscribedPurchaseService())
        await subscription.refresh()
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: TabletEditor(workspace: workspace))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            workspace.client.stop()
            window.isHidden = true
            previous?.makeKey()
            try? FileManager.default.removeItem(at: root)
        }
        try await workspace.open(workspace.library.create(title: "styling", text: source))
        workspace.layout = .writing
        let deadline = ContinuousClock.now + .seconds(30)
        while (workspace.editor as? TabletTextView)?.text != source, deadline > .now {
            try await Task.sleep(for: .milliseconds(50))
        }
        let editor = try #require(workspace.editor as? TabletTextView)
        let styler = try #require(editor.styler)
        controller.view.layoutIfNeeded()
        await styler.settled()
        let text = source as NSString
        let font = { (substring: String) in
            editor.textStorage.attribute(.font, at: text.range(of: substring).location, effectiveRange: nil) as? UIFont
        }
        let body = try #require(font("Text"))
        #expect(font("Title")?.pointSize == body.pointSize + 6)
        #expect(font("Section")?.pointSize == body.pointSize + 4)
        #expect(font("strong")?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(font("emph")?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        #expect(font("code")?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        #expect(font("#item") == body && font("$φ") == body)

        // TextKit lays out the source itself: no attachments, no hidden text.
        let manager = try #require(editor.textLayoutManager)
        let content = try #require(manager.textContentManager as? NSTextContentStorage)
        manager.ensureLayout(for: manager.documentRange)
        let laidOut = NSMutableAttributedString()
        content.enumerateTextElements(from: content.documentRange.location) { element in
            if let paragraph = element as? NSTextParagraph {
                laidOut.append(paragraph.attributedString)
            }
            return true
        }
        #expect(laidOut.string == source)
        var attachments = 0
        for string in [laidOut, editor.textStorage] {
            string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
                attachments += value == nil ? 0 : 1
            }
        }
        #expect(attachments == 0)

        // A heading typed at the caret takes its size; the caret stays put.
        let end = text.range(of: "$φ").location
        editor.selectedRange = NSRange(location: end, length: 0)
        editor.insertText("= New\n")
        let caret = editor.selectedRange
        await styler.settled()
        let typed = editor.textStorage.attribute(.font, at: end + 2, effectiveRange: nil) as? UIFont
        #expect(typed?.pointSize == body.pointSize + 6)
        #expect(editor.selectedRange == caret)
        #expect(workspace.text == editor.text)
    }
}
