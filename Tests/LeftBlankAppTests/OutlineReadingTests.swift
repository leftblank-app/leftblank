import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func longOutlineFollowsScrollingFoldsAndRemembersChoices() async throws {
        let source = (1 ... 8).map { chapter in
            "= Chapter \(chapter)\n\n" + (1 ... 5).map { section in
                "== Section \(section)\n\n" + String(repeating: "A paragraph for scrolling. 中文😀\n\n", count: 5)
            }.joined()
        }.joined()
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        app.workspace.startService()
        try await app.ready()
        try await app.wait { app.workspace.outline.count == 48 }
        let workspace = app.workspace
        #expect(workspace.outlineNavigation.visibleIndices.count == 8)
        workspace.toggleOutlineSection(0)
        #expect(workspace.outlineNavigation.visibleIndices.count == 13)
        let foldedKeys = workspace.outlineNavigation.expansion.expanded
        let firstOffset = try #require(workspace.outline.first?.offset)
        editor.insertSnippet(Snippet(text: "A new introduction.\n\n"), replacing: NSRange(location: 0, length: 0))
        try await app.wait { workspace.outline.first?.offset ?? 0 > firstOffset }
        #expect(workspace.outlineNavigation.expansion.expanded == foldedKeys)
        #expect(workspace.outlineNavigation.visibleIndices.count == 13)

        // Scroll without moving the caret: the final section still has a mark,
        // even when its row is hidden under a folded chapter.
        editor.reveal(NSRange(location: editor.string.utf16.count, length: 0))
        try await app.wait { (workspace.activeOutlineIndex ?? 0) >= 45 }
        let active = try #require(workspace.activeOutlineIndex)
        let buckets = workspace.outlineNavigation.minimapBuckets()
        #expect(buckets.count == 18)
        #expect(buckets.last?.contains(active) == true)
        #expect(buckets.flatMap { Array($0) } == Array(workspace.outline.indices))
        #expect(workspace.outlineNavigation.visibleAncestor(of: active) == 42)
        #expect(editor.selectedRange().location < workspace.outline[1].offset)
        try workspace.execute(#require(WritingCommand.all.first { $0.id == "outlineExpand" }))
        #expect(workspace.outlineNavigation.visibleIndices.count == 48)
        try workspace.execute(#require(WritingCommand.all.first { $0.id == "outlineCollapse" }))
        #expect(workspace.outlineNavigation.visibleIndices.count == 8)
        workspace.toggleOutlineSection(42)
        #expect(workspace.outlineNavigation.visibleIndices.contains(active))
        workspace.saveRecovery()
        let recovered = Workspace(stateDirectory: workspace.stateDirectory)
        recovered.outline = workspace.outline
        #expect(recovered.outlineNavigation.expansion.expanded == workspace.outlineNavigation.expansion.expanded)
        recovered.shutdown()
    }

    @Test func titleUsesAvailableToolbarSpaceAndShrinksInNarrowWindows() async throws {
        let app = try WritingFixture(text: "= Book\n", startService: false)
        defer { app.close() }
        app.workspace.managedTitle = "Structure and Interpretation of Computer Programs"
        await app.layout()
        let item = try #require(app.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "LeftBlankDocument" })
        let view = try #require(item.view)
        let wide = view.fittingSize.width
        #expect(wide > 340)
        app.workspace.managedTitle = String(repeating: "A very long title ", count: 10)
        await app.layout()
        let long = view.fittingSize.width
        #expect(long > wide)
        app.window.setContentSize(NSSize(width: 620, height: 540))
        await app.layout()
        let narrow = view.fittingSize.width
        #expect(narrow < long)
        #expect(narrow <= app.window.frame.width - 300)
    }
}
