import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func commandClickFollowsLocalImportIncludeAndModuleMembers() async throws {
        let source = "// 中文 😀\n#import \"模块.typ\" as shared\n#include \"chapter.typ\"\n#shared.greeting(\"Reader\")\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let module = app.root.appendingPathComponent("模块.typ")
        let nested = app.root.appendingPathComponent("nested/values.typ")
        let chapter = app.root.appendingPathComponent("chapter.typ")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("#let title = [Hello]\n".utf8).write(to: nested)
        try Data("#import \"nested/values.typ\": title\n#let greeting(name) = [#title #name]\n".utf8).write(to: module)
        try Data("= Chapter\n".utf8).write(to: chapter)
        app.workspace.startService()
        try await app.ready()
        let editor = try #require(app.workspace.editor)

        let origin = try app.commandClick("模块.typ")
        try await app.wait { app.workspace.documentURL == module }
        #expect(editor.isEditable)
        #expect(app.workspace.compilationURL == app.document)
        try await app.ready()
        let nestedOrigin = try app.commandClick("nested/values.typ")
        try await app.wait { app.workspace.documentURL == nested }
        #expect(editor.isEditable)
        app.workspace.closeDocument()
        #expect(app.workspace.documentURL == module)
        #expect(app.workspace.selection.location == nestedOrigin)
        app.workspace.navigateBack()
        #expect(app.workspace.documentURL == app.document)
        #expect(app.workspace.selection.location == origin)
        try await app.ready()

        let includeOrigin = (source as NSString).range(of: "chapter.typ").location + 2
        editor.setSelectedRange(NSRange(location: includeOrigin, length: 0))
        editor.keyDown(with: app.key("\u{f70f}", code: 111, modifiers: .function))
        try await app.wait { app.workspace.documentURL == chapter }
        app.workspace.navigateBack()
        #expect(app.workspace.selection.location == includeOrigin)
        try await app.ready()

        _ = try app.commandClick("greeting")
        try await app.wait { app.workspace.documentURL == module }
        #expect(app.workspace.position.line == 1)
        #expect(app.workspace.compilationURL == app.document)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == source)
    }

    @Test func packageDefinitionsAndTheirImportsStayReadOnlyAndReturnToSource() async throws {
        let source = "#import \"@preview/cetz:0.5.2\": canvas\n#canvas({})\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let library = app.workspace.packageCache.appendingPathComponent("preview/cetz/0.5.2/src/lib.typ")
        let canvas = library.deletingLastPathComponent().appendingPathComponent("canvas.typ")
        let original = try Data(contentsOf: canvas)
        let origin = try app.commandClick("@preview/cetz:0.5.2")
        try await app.wait { app.workspace.documentURL == library }
        #expect(app.workspace.isPackageSource)
        #expect(!editor.isEditable)
        try await app.ready()
        let libraryOrigin = try app.commandClick("canvas.typ")
        try await app.wait { app.workspace.documentURL == canvas }
        #expect(!editor.isEditable)
        #expect(app.workspace.compilationURL == app.document)
        app.workspace.navigateBack()
        #expect(app.workspace.documentURL == library)
        #expect(app.workspace.selection.location == libraryOrigin)
        app.workspace.navigateBack()
        #expect(app.workspace.documentURL == app.document)
        #expect(app.workspace.selection.location == origin)
        #expect(editor.isEditable)
        try await app.ready()

        let call = (source as NSString).range(of: "#canvas").location + 3
        editor.setSelectedRange(NSRange(location: call, length: 0))
        app.workspace.goToDefinition()
        try await app.wait { app.workspace.documentURL == canvas }
        let expected = (app.workspace.text as NSString).range(of: "#let canvas").location + 5
        #expect(app.workspace.selection.location == expected)
        #expect(!editor.isEditable)
        app.workspace.closeDocument()
        #expect(app.workspace.documentURL == app.document)
        #expect(app.workspace.selection.location == call)
        #expect(try Data(contentsOf: canvas) == original)
    }

    @Test func definitionFindsFunctionsAndReferencesAndDiscardsSupersededRequests() async throws {
        let source = "#set heading(numbering: \"1.\")\n#let greeting(name) = [Hello #name]\n#greeting(\"Reader\")\n\n= Introduction <intro>\nSee @intro.\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        try await app.wait { app.workspace.checksPassed }
        let editor = try #require(app.workspace.editor)
        let call = (source as NSString).range(of: "#greeting").location + 3
        editor.setSelectedRange(NSRange(location: call, length: 0))
        app.workspace.goToDefinition()
        let definition = (source as NSString).range(of: "greeting(name)").location
        try await app.wait { app.workspace.selection.location == definition }
        app.workspace.navigateBack()
        #expect(app.workspace.selection.location == call)
        let reference = (source as NSString).range(of: "@intro").location + 3
        editor.setSelectedRange(NSRange(location: reference, length: 0))
        app.workspace.goToDefinition()
        try await app.wait { app.workspace.position.line == 4 }
        app.workspace.navigateBack()
        #expect(app.workspace.selection.location == reference)

        editor.setSelectedRange(NSRange(location: call, length: 0))
        app.workspace.goToDefinition()
        // Returning to the same caret must not resurrect an abandoned request.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: call, length: 0))
        try await Task.sleep(for: .milliseconds(350))
        #expect(app.workspace.selection.location == call)
        #expect(app.workspace.assistance == nil)
        #expect(editor.string == source)
    }
}

extension WritingFixture {
    /// Exercise native text geometry and the real command-click handler.
    @discardableResult func commandClick(_ needle: String) throws -> Int {
        let editor = try #require(workspace.editor)
        let range = (editor.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound)
        let offset = range.location + 1
        editor.scrollRangeToVisible(NSRange(location: offset, length: 1))
        editor.prepareForPointerInteraction()
        let rect = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
        let point = window.convertFromScreen(NSRect(x: rect.minX + 1, y: rect.midY, width: 0, height: 0)).origin
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        try #require(editor.sourceOffset(at: event) == offset)
        editor.mouseDown(with: event)
        return offset
    }
}
