import AppKit
import Foundation
@testable import LeftBlankApp
import LeftBlankCore
import LeftBlankTestSupport
import Testing
import WebKit

@Suite(.serialized) @MainActor struct PreviewContinuityTests {
    @Test func normalizedReadingAnchorSurvivesZoomAndSourceJumpCancelsRestore() async throws {
        let fixture = PreviewReadingFixture(script: PreviewScripts.reading)
        defer { fixture.close() }
        try await fixture.ready()
        let web = fixture.web
        let anchor = try #require(PreviewReadingAnchor(page: 1, x: 0.5, y: 0.35, viewportY: 0.2))
        #expect(try await web
            .evaluateJavaScript("window.leftblankRestoreReading(\(anchor.javaScript))") as? Bool == true)
        try await Task.sleep(for: .milliseconds(500))
        let beforeMessage = try #require(await web.evaluateJavaScript("window.leftblankCaptureReading()"))
        let before = try #require(PreviewReadingAnchor(message: beforeMessage))
        #expect(before.page == 1)
        #expect(abs(before.y - anchor.y) < 0.02)
        try await web
            .evaluateJavaScript(
                "window.leftblankPrepareResize(); document.getElementById('typst-container').style.width = '140%'; window.dispatchEvent(new Event('resize'));",
            )
        try await Task.sleep(for: .milliseconds(500))
        let zoomedMessage = try #require(await web.evaluateJavaScript("window.leftblankCaptureReading()"))
        let zoomed = try #require(PreviewReadingAnchor(message: zoomedMessage))
        #expect(zoomed.page == before.page)
        #expect(abs(zoomed.y - before.y) < 0.02)
        try await web
            .evaluateJavaScript(
                "window.leftblankPrepareResize(); window.leftblankSourceJump(); document.getElementById('typst-container-main').scrollTop = 0;",
            )
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await web
            .evaluateJavaScript("document.getElementById('typst-container-main').scrollTop") as? Double == 0)
        // A shortened document must still provide a bounded, valid return.
        try await web.evaluateJavaScript("document.querySelectorAll('.typst-page-inner')[2].remove();")
        #expect(try await web
            .evaluateJavaScript("window.leftblankRestoreReading({page:99,x:.5,y:.3,viewportY:.2})") as? Bool == true)
        #expect(try await web
            .evaluateJavaScript("window.leftblankRestoreReading({page:-1,x:.5,y:.3,viewportY:.2})") as? Bool == false)
    }

    @Test func nativeReturnRestoresBookmarkedPageAndAcknowledgesSuccess() async throws {
        let fixture = PreviewReadingFixture(script: PreviewScripts.reading)
        defer { fixture.close() }
        try await fixture.ready()
        let session = PreviewReadingSession()
        let coordinator = PreviewView.Coordinator(readingSession: session, onError: { _ in })
        try session.observe(#require(PreviewReadingAnchor(page: 2, x: 0.5, y: 0.4, viewportY: 0.2)))
        session.rememberReturnPosition()
        session.returnToReading()
        coordinator.restoreReading(in: fixture.web)
        let deadline = ContinuousClock.now + .seconds(5)
        while session.restore != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(session.restore == nil)
        #expect(session.returnAnchor == nil)
        try await Task.sleep(for: .milliseconds(500))
        let result = try #require(await fixture.web.evaluateJavaScript("window.leftblankCaptureReading()"))
        let anchor = try #require(PreviewReadingAnchor(message: result))
        #expect(anchor.page == 2)
        #expect(abs(anchor.y - 0.4) < 0.02)
    }

    @Test func nativeReadingBridgePausesFollowAndRetainsBookmark() {
        let session = PreviewReadingSession()
        let coordinator = PreviewView.Coordinator(readingSession: session, onError: { _ in })
        coordinator.receiveReading([
            "kind": "anchor",
            "anchor": ["page": 2, "x": 0.5, "y": 0.4, "viewportY": 0.2] as [String: Any],
        ])
        session.rememberReturnPosition()
        session.followsWriting = true
        coordinator.receiveReading(["kind": "manualScroll"])
        #expect(!session.followsWriting)
        #expect(session.returnAnchor?.page == 2)
        let web = PreviewWebView()
        var invalidations = 0
        web.onWillLoad = { invalidations += 1 }
        _ = web.reload()
        #expect(invalidations == 1)
    }
}
