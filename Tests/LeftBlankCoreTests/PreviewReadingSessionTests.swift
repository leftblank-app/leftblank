import Foundation
import LeftBlankCore
import Testing

@MainActor struct PreviewReadingSessionTests {
    @Test func returnBookmarkSurvivesNewAnchorsAndRejectsStaleAcknowledgements() throws {
        let session = PreviewReadingSession()
        let anchor = try #require(PreviewReadingAnchor(page: 4, x: 0.5, y: 0.6, viewportY: 0.2))
        session.observe(anchor)
        session.followsWriting = true
        session.rememberReturnPosition()
        #expect(!session.followsWriting)
        try session.observe(#require(PreviewReadingAnchor(page: 0, x: 0.5, y: 0, viewportY: 0.2)))
        session.returnToReading()
        let first = try #require(session.restore)
        #expect(first.anchor == anchor)
        session.returnToReading()
        let next = try #require(session.restore)
        session.didRestore(first.id)
        #expect(session.restore == next)
        #expect(session.returnAnchor == anchor)
        session.didRestore(next.id)
        #expect(session.restore == nil)
        #expect(session.returnAnchor == nil)
    }

    @Test func reloadPreservesCurrentPositionAndReturnBookmark() throws {
        let session = PreviewReadingSession()
        let bookmark = try #require(PreviewReadingAnchor(page: 4, x: 0.5, y: 0.6, viewportY: 0.2))
        session.observe(bookmark)
        session.rememberReturnPosition()
        let current = try #require(PreviewReadingAnchor(page: 1, x: 0.5, y: 0.2, viewportY: 0.2))
        session.observe(current)
        session.prepareReload()
        let reload = try #require(session.restore)
        #expect(reload.anchor == current)
        session.didRestore(reload.id)
        #expect(session.returnAnchor == bookmark)
        session.returnToReading()
        let returning = try #require(session.restore)
        session.prepareReload()
        #expect(session.restore == returning)
        session.didRestore(returning.id)
        #expect(session.returnAnchor == nil)
    }

    @Test func resetDropsDocumentSpecificReadingState() throws {
        let session = PreviewReadingSession()
        try session.observe(#require(PreviewReadingAnchor(page: 1, x: 0.5, y: 0.2, viewportY: 0.2)))
        session.rememberReturnPosition()
        session.returnToReading()
        session.followsWriting = true
        session.reset()
        #expect(session.anchor == nil)
        #expect(session.returnAnchor == nil)
        #expect(session.restore == nil)
        #expect(!session.followsWriting)
    }

    @Test func invalidMessagesCannotProduceJavaScriptOrReadingPositions() {
        #expect(PreviewReadingAnchor(page: -1, x: 0, y: 0, viewportY: 0) == nil)
        #expect(PreviewReadingAnchor(page: 0, x: .nan, y: 0, viewportY: 0) == nil)
        #expect(PreviewReadingAnchor(page: 0, x: 0, y: .infinity, viewportY: 0) == nil)
        #expect(PreviewReadingAnchor(page: 0, x: 0, y: 2, viewportY: 0) == nil)
        #expect(PreviewReadingAnchor(message: ["page": "0", "x": 0, "y": 0, "viewportY": 0]) == nil)
    }
}
