import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import SwiftUI
import Testing
import UIKit

/// Rotation and Split View re-wrap the text. UIKit's first sizing of the
/// re-wrapped text clamps the scroll, which threw the reader back to the start
/// of a book; the editor puts its top line back.
@Suite(.serialized)
@MainActor
struct TabletResizeTests {
    @Test func resizingDeepInADocumentKeepsTheTopLine() async throws {
        let paragraph = "A paragraph of plain words that wraps across the writing column.\n\n"
        let source = String(repeating: paragraph, count: 20000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resize-" + UUID().uuidString)
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
        try await workspace.open(workspace.library.create(title: "resize", text: source))
        workspace.layout = .writing
        let deadline = ContinuousClock.now + .seconds(60)
        while (workspace.editor as? TabletTextView)?.text.utf16.count != source.utf16.count, deadline > .now {
            try await Task.sleep(for: .milliseconds(50))
        }
        let editor = try #require(workspace.editor as? TabletTextView)
        controller.view.layoutIfNeeded()
        await editor.styler?.settled()
        let manager = try #require(editor.textLayoutManager)
        workspace.jump(workspace.metrics.position(at: (source as NSString).length / 2))
        window.layoutIfNeeded()
        let top = { TextKit2Geometry.viewportInsertionOffset(at: editor.containerVisibleRect().origin, in: manager) }
        let line = try #require(top())
        let built = SourceStyler.paragraphsBuilt
        window.frame = CGRect(x: 0, y: 0, width: window.frame.width * 0.6, height: window.frame.height)
        window.layoutIfNeeded()
        let after = try #require(top())
        let shown = try #require(TextKit2Geometry.displayedRange(in: editor.containerVisibleRect(), manager: manager))
        // Re-wrapped, the anchor's line may start up to a line earlier.
        #expect(NSLocationInRange(line, shown) && abs(after - line) < 300, "Top line \(line) became \(after)")
        #expect(SourceStyler.paragraphsBuilt - built < 500)
    }
}
