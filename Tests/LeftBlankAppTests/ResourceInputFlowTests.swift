import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import PDFKit
import Testing

extension WritingFlowTests {
    @Test func resourcePasteboardPreservesPlainPathsAndPrefersFilesOverIcons() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.setString("file:///Users/example/figure.png", forType: .string))
        #expect(ResourcePasteboard(pasteboard) == nil)
        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/Users/example/figure.png")
        #expect(pasteboard.writeObjects([file as NSURL]))
        #expect(pasteboard.setData(Data("Finder icon".utf8), forType: .tiff))
        let resource = try #require(ResourcePasteboard(pasteboard))
        #expect(resource.inputs.count == 1)
        guard case let .file(selected) = resource.inputs[0] else {
            Issue.record("Finder's image icon must not replace the original file")
            return
        }
        #expect(selected == file)
    }

    @Test func finderImageDropImportsAtTheDropPositionAndUndoRedoKeepTheCopies() async throws {
        let source = "Before\n\nAfter\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        app.workspace.styledSource = false
        let first = app.root.appendingPathComponent("图片 \"一\".svg")
        let second = app.root.appendingPathComponent("second.svg")
        let svg = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\"><rect width=\"24\" height=\"24\" fill=\"red\"/></svg>"
                .utf8,
        )
        try svg.write(to: first)
        try svg.write(to: second)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([first as NSURL, second as NSURL]))
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        editor.prepareForPointerInteraction()
        let rect = try #require(editor.characterRect(at: 8))
        let point = NSPoint(x: rect.minX, y: rect.midY)
        let drag = ResourceDrag(pasteboard: pasteboard, window: app.window, location: editor.convert(point, to: nil))
        #expect(editor.draggingEntered(drag) == .copy)
        #expect(editor.draggingUpdated(drag) == .copy)
        #expect(editor.prepareForDragOperation(drag))
        #expect(editor.performDragOperation(drag))
        try await app.wait { app.workspace.text.contains("#figure(") && !app.workspace.applyingCommand }
        #expect(editor.string.hasPrefix("Before\n\n#figure("))
        #expect(editor.string.hasSuffix("After\n"))
        #expect(editor.string.components(separatedBy: "#figure(").count == 3)
        #expect(!editor.string.contains(app.root.path))
        #expect(editor.string == app.workspace.text)
        let inserted = editor.string
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        let resources = try await app.workspace.resourceStore.list(kind: .image, in: app.root, relativeTo: app.document)
            .filter { $0.relativePath.hasPrefix("assets/") }
        #expect(resources.count == 2)
        #expect(try Data(contentsOf: resources[0].url) == svg)
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        editor.undoManager?.redo()
        #expect(editor.string == inserted)
        let pdf = app.root.appendingPathComponent("with-images.pdf")
        try await app.workspace.exportPDF(to: pdf)
        #expect(try #require(PDFDocument(url: pdf)).pageCount > 0)
    }

    @Test func screenshotPasteImportsPNGWhilePlainTextPasteStaysText() async throws {
        let app = try WritingFixture(text: "Before after\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
        ))
        for x in 0 ..< 2 {
            for y in 0 ..< 2 {
                bitmap.setColor(.blue, atX: x, y: y)
            }
        }
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        #expect(pasteboard.setData(tiff, forType: .tiff))
        editor.setSelectedRange(NSRange(location: 7, length: 5))
        #expect(editor.readSelection(from: pasteboard, type: .tiff))
        try await app.wait { app.workspace.text.contains("#figure(") && !app.workspace.applyingCommand }
        #expect(!editor.string.contains("after"))
        let resources = try await app.workspace.resourceStore.list(kind: .image, in: app.root, relativeTo: app.document)
        let resource = try #require(resources.first)
        #expect(resource.url.pathExtension == "png")
        #expect(NSImage(contentsOf: resource.url)?.size == NSSize(width: 2, height: 2))
        pasteboard.clearContents()
        #expect(pasteboard.setString("Plain text 中文😀", forType: .string))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string.hasSuffix("Plain text 中文😀"))
        #expect(editor.string == app.workspace.text)
    }

    @Test func imagePaletteUsesAFilePickerAndReusesResourcesWithoutCopyingAgain() async throws {
        let app = try WritingFixture(text: "= Resources\n\nBody\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let image = try #require(WritingCommand.all.first { $0.id == "image" })
        let original = app.root.appendingPathComponent("figure.svg")
        try Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><circle cx=\"10\" cy=\"10\" r=\"8\"/></svg>"
                .utf8,
        ).write(to: original)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count - 1, length: 0))
        app.window.sendEvent(app.key(app.workspace.commandKey, code: 38, modifiers: .command))
        app.window.sendEvent(app.key("i", code: 34))
        app.window.sendEvent(app.key("i", code: 34))
        #expect(app.workspace.activeCommand?.id == "image")
        #expect(image.fields.first?.resourceKind == .image)
        await app.layout()
        func fields(_ view: NSView) -> [FocusTextField] {
            (view as? FocusTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        #expect(try #require(app.window.contentView).subviews.flatMap(fields).count == 1)
        app.workspace.closePalette()
        #expect(app.workspace.resourceSelection == nil)
        #expect(editor.string == "= Resources\n\nBody\n")
        app.workspace.togglePalette()
        app.workspace.selectCommand(image)
        app.workspace.resourceSelection = .file(original)
        app.workspace.fieldValues["caption"] = "An imported figure"
        app.workspace.execute(image)
        try await app.wait { !app.workspace.applyingCommand }
        try #require(!app.workspace.paletteOpen, "Command error: \(app.workspace.commandError ?? "none")")
        #expect(editor.string.contains("An imported figure"))
        let before = try await app.workspace.resourceStore.list(kind: .image, in: app.root, relativeTo: app.document)
        let imported = try #require(before.first { $0.relativePath.hasPrefix("assets/") })
        app.workspace.togglePalette()
        app.workspace.selectCommand(image)
        try await app.wait { !app.workspace.availableResources.isEmpty }
        try #require(
            app.workspace.availableResources.contains(imported),
            "Available: \(app.workspace.availableResources); imported: \(imported)",
        )
        app.workspace.resourceSelection = .existing(imported)
        app.workspace.execute(image)
        try await app.wait { !app.workspace.applyingCommand }
        try #require(!app.workspace.paletteOpen, "Command error: \(app.workspace.commandError ?? "none")")
        #expect(try await app.workspace.resourceStore.list(kind: .image, in: app.root, relativeTo: app.document)
            .count == before.count)
        #expect(editor.string.components(separatedBy: imported.relativePath).count == 3)
    }

    @Test func resourceInputRejectsUnsupportedFilesCodeAndMarkedTextWithoutPastingPaths() async throws {
        let app = try WritingFixture(text: "Body\n\n$ x^2 $\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let video = app.root.appendingPathComponent("movie.mp4")
        try Data("video".utf8).write(to: video)
        #expect(pasteboard.writeObjects([video as NSURL]))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let source = editor.string
        #expect(editor.readSelection(from: pasteboard, type: .fileURL))
        try await app.wait { app.workspace.message != nil && !app.workspace.applyingCommand }
        #expect(editor.string == source)
        #expect(app.workspace.message == DocumentResourceError.unsupported.localizedDescription)
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        app.workspace.message = nil
        #expect(editor.readSelection(from: pasteboard, type: .fileURL))
        try await app.wait { app.workspace.message != nil && !app.workspace.applyingCommand }
        #expect(editor.string == source)
        let assets = app.root.appendingPathComponent("assets")
        #expect(try FileManager.default.contentsOfDirectory(atPath: assets.path).isEmpty)
        editor.setMarkedText(
            "拼音",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: editor.selectedRange(),
        )
        let marked = editor.string
        #expect(editor.readSelection(from: pasteboard, type: .fileURL))
        #expect(editor.string == marked)
        #expect(editor.hasMarkedText())
        editor.unmarkText()
    }

    @Test func bibliographyDropAndModulePickerCopyFilesIntoTheDocument() async throws {
        let app = try WritingFixture(text: "Body\n")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let bibliography = app.root.appendingPathComponent("references.bib")
        try Data("@book{example, title={Example}, author={Writer}, year={2025}}".utf8).write(to: bibliography)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([bibliography as NSURL]))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        #expect(editor.readSelection(from: pasteboard, type: .fileURL))
        try await app.wait { editor.string.contains("#bibliography(") && !app.workspace.applyingCommand }
        #expect(!editor.string.contains(bibliography.path))
        let module = app.root.appendingPathComponent("helpers.typ")
        try Data("#let example = 1\n".utf8).write(to: module)
        app.workspace.togglePalette()
        let command = try #require(WritingCommand.all.first { $0.id == "import" })
        app.workspace.selectCommand(command)
        app.workspace.resourceSelection = .file(module)
        app.workspace.execute(command)
        try await app.wait { !app.workspace.paletteOpen && !app.workspace.applyingCommand }
        #expect(editor.string.hasPrefix("#import \"assets/"))
        #expect(editor.string.contains("helpers.typ\": *"))
        #expect(!editor.string.contains(module.path))
        let pdf = app.root.appendingPathComponent("resources.pdf")
        try await app.workspace.exportPDF(to: pdf)
        #expect(PDFDocument(url: pdf) != nil)
    }
}

/// Native drag destination entry points receive a pasteboard and window-space
/// pointer position. This fixture supplies those while leaving rendering native.
@MainActor
private final class ResourceDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = .copy
    let draggedImageLocation: NSPoint = .zero
    nonisolated var draggedImage: NSImage? {
        nil
    }

    var draggingSource: Any? {
        nil
    }

    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight {
        .none
    }

    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingLocation = location
    }

    func slideDraggedImage(to _: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions, for _: NSView?, classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void,
    ) {}
}
