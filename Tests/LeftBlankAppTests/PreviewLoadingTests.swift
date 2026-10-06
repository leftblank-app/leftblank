import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing
import WebKit

extension WritingFlowTests {
    @Test func previewCoversBlankPaneUntilFirstPaintAndAgainAfterReopen() async throws {
        let app = try WritingFixture(text: "= Loading sentinel\n\nA short paragraph.\n")
        defer { app.close() }
        app.workspace.layout = .split
        #expect(!app.workspace.previewPainted)
        #expect(previewSpinnerShown(app))
        try await app.ready()
        try await paintPreview(app)

        // Opening another document restarts typesetting; its new page has not painted yet.
        let next = app.root.appendingPathComponent("next.typ")
        try Data("= Next document\n\nMore words.\n".utf8).write(to: next)
        #expect(app.workspace.open(next))
        #expect(!app.workspace.previewPainted)
        #expect(previewSpinnerShown(app))
        try await app.ready()
        try await paintPreview(app)

        // A ready message for another page must not uncover the current one.
        let current = try #require(app.workspace.previewURL)
        app.workspace.previewWillLoad(at: current)
        #expect(!app.workspace.previewPainted)
        app.workspace.previewDidBecomeReady(at: URL(fileURLWithPath: "/stale-preview"))
        #expect(!app.workspace.previewPainted)
        app.workspace.previewDidBecomeReady(at: current)
        #expect(app.workspace.previewPainted)

        app.workspace.showLibraryHome()
        #expect(!app.workspace.previewPainted)
        #expect(app.workspace.previewURL == nil)
    }

    @Test func failedFirstCompileShowsAttentionInPreviewUntilFixed() async throws {
        let app = try WritingFixture(text: "= Broken\n\n#undefined-function()\n")
        defer { app.close() }
        app.workspace.layout = .split
        try await app.ready()
        try await app.wait { app.workspace.previewNeedsAttention }
        #expect(!app.workspace.previewPainted)
        #expect(app.workspace.checkErrors > 0)
        try await app.wait {
            previewCovered(app) == true && !previewSpinnerShown(app)
        }

        let editor = try #require(app.workspace.editor)
        let broken = (editor.string as NSString).range(of: "#undefined-function()")
        editor.insertSnippet(Snippet(text: "Fixed words."), replacing: broken)
        try await app.wait { app.workspace.hasSuccessfulPreview }
        #expect(!app.workspace.previewNeedsAttention)
        try await paintPreview(app)
    }
}

/// A hidden test window has no display ticks, so drive animation frames with a
/// timer and reload; the real Tinymist renderer then reports its first paint.
@MainActor
private func paintPreview(_ app: WritingFixture) async throws {
    await app.layout()
    let web = try #require(findPreviewWebView(app.window.contentView))
    web.configuration.preferences.inactiveSchedulingPolicy = .none
    web.configuration.userContentController.addUserScript(WKUserScript(
        source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16); window.cancelAnimationFrame = clearTimeout;",
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
    ))
    web.reload()
    // Nothing has awaited since reload, so the page cannot have reported a paint yet.
    #expect(!app.workspace.previewPainted, "Reloading the page must cover it again")
    #expect(previewCovered(app) == true, "The mounted web view stays under the placeholder")
    try await app.wait { app.workspace.previewPainted }
    try await app.wait { previewCovered(app) == false && !previewSpinnerShown(app) }
}

/// Whether a click at the web view's centre lands on SwiftUI content above it
/// rather than on the page; nil when no web view is mounted.
@MainActor
private func previewCovered(_ app: WritingFixture) -> Bool? {
    guard let root = app.window.contentView, let web = findPreviewWebView(root) else {
        return nil
    }
    root.layoutSubtreeIfNeeded()
    let center = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: root.superview)
    guard let hit = root.hitTest(center) else {
        return true
    }
    return !hit.isDescendant(of: web)
}

@MainActor
private func previewSpinnerShown(_ app: WritingFixture) -> Bool {
    func contains(_ view: NSView) -> Bool {
        view is NSProgressIndicator || view.subviews.contains(where: contains)
    }
    app.window.contentView?.layoutSubtreeIfNeeded()
    return app.window.contentView.map(contains) ?? false
}

@MainActor
private func findPreviewWebView(_ view: NSView?) -> WKWebView? {
    guard let view else {
        return nil
    }
    if let web = view as? WKWebView {
        return web
    }
    return view.subviews.lazy.compactMap { findPreviewWebView($0) }.first
}
