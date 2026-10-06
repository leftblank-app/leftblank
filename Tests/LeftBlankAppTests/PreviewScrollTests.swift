import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import Testing
import WebKit

/// Tinymist's partial renderer paints pages only after scrolling has stopped
/// for 500 ms. These checks use the real side-by-side preview and count glyphs
/// in the pages that the viewport shows.
extension WritingFlowTests {
    @Test func shortPreviewPaintsEveryPageBeforeScrolling() async throws {
        let web = try await openScrollPreview(pages: 3)
        defer { web.app.close() }
        try await waitForJavaScript(web.view, condition: "\(Self.pageGlyphs).every(count => count > 20)")
        #expect(try await web.view.evaluateJavaScript("\(Self.renderer).partialRendering") as? Bool == false)
        // Every page is already painted, so a scroll never reveals a blank page.
        let painted = try await web.view.evaluateJavaScript("""
        (() => {
            const host = document.getElementById('typst-container-main');
            host.scrollTop = host.scrollHeight;
            return \(Self.visibleGlyphs).every(count => count > 20);
        })()
        """)
        #expect(painted as? Bool == true)
    }

    @Test func longPreviewPaintsAheadAndWhileScrolling() async throws {
        let pages = PreviewScripts.fullRenderingPageLimit + 4
        let web = try await openScrollPreview(pages: pages)
        defer { web.app.close() }
        #expect(try await web.view.evaluateJavaScript("\(Self.renderer).partialRendering") as? Bool == true)
        // The page below the viewport is painted before the reader reaches it.
        try await waitForJavaScript(web.view, condition: "\(Self.pageGlyphs)[1] > 20")
        #expect(try await web.view.evaluateJavaScript("\(Self.pageGlyphs).at(-1)") as? Int == 0)
        // Keep scrolling near a distant page. Tinymist's own repaint waits for
        // 500 ms without scroll events, so only the scroll-time repaint can
        // paint this page before the scrolling stops.
        let target = pages - 2
        let nudge = """
        (() => {
            const host = document.getElementById('typst-container-main');
            const page = document.querySelector('.typst-doc > g.typst-page[data-page-number="\(target)"]');
            const top = host.scrollTop + page.getBoundingClientRect().top - host.getBoundingClientRect().top;
            host.scrollTop = Math.abs(host.scrollTop - top) < 1 ? top + 2 : top;
            return page.querySelectorAll('use').length;
        })()
        """
        var glyphs = 0
        let deadline = ContinuousClock.now + .seconds(4)
        while glyphs <= 20, ContinuousClock.now < deadline {
            glyphs = try await web.view.evaluateJavaScript(nudge) as? Int ?? 0
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(glyphs > 20, "A distant page must be painted while scrolling continues")
    }

    private static let renderer = "document.getElementById('typst-container').documents[0].impl"
    private static let pageGlyphs =
        "[...document.querySelectorAll('.typst-doc > g.typst-page')].map(page => page.querySelectorAll('use').length)"
    private static let visibleGlyphs = """
    [...document.querySelectorAll('.typst-doc > g.typst-page')].filter(page => {
        const bounds = page.getBoundingClientRect();
        return bounds.bottom > 0 && bounds.top < innerHeight;
    }).map(page => page.querySelectorAll('use').length)
    """

    private func openScrollPreview(pages: Int) async throws -> (app: WritingFixture, view: WKWebView) {
        let paragraph = String(repeating: "Scrolling must never reveal an unpainted page. ", count: 12)
        let source = (1 ... pages).map { "= Page \($0)\n\n\(paragraph)\n" }.joined(separator: "\n#pagebreak()\n")
        let app = try WritingFixture(text: source)
        do {
            try await app.ready()
            app.workspace.layout = .split
            await app.layout()
            let web = try #require(findWebView(app.window.contentView))
            // A hidden test window has no display ticks; drive animation frames.
            web.configuration.preferences.inactiveSchedulingPolicy = .none
            web.configuration.userContentController.addUserScript(WKUserScript(
                source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16); window.cancelAnimationFrame = clearTimeout;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
            ))
            web.reload()
            try await waitForJavaScript(
                web,
                condition: "document.querySelectorAll('.typst-doc > g.typst-page').length === \(pages) && \(Self.pageGlyphs)[0] > 20",
            )
            return (app, web)
        } catch {
            app.close()
            throw error
        }
    }
}
