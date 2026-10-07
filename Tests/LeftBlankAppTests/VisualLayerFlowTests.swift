import AppKit
@testable import LeftBlankApp
@testable import LeftBlankCore
import Testing

/// The visual layer in the real Mac editor: concealment and instant reveal,
/// chips and their forms, repeat-previous, inline images and equations.
extension WritingFlowTests {
    @Test func markupIsConcealedOutsideTheCaretAndRevealedOnEntry() async throws {
        let source = "= Title\n\nText *strong* and _emph_ with `code`, @intro and <lab>.\n\n- item\n\nEnd\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let text = source as NSString
        editor.setSelectedRange(NSRange(location: text.length - 1, length: 0))
        await app.settle(editor)
        let star = text.range(of: "*strong").location
        let underscore = text.range(of: "_emph").location
        for (offset, name) in [(0, "="), (1, "space"), (star, "*"), (underscore, "_"),
                               (text.range(of: "`code").location, "`"), (text.range(of: "@intro").location, "@"),
                               (text.range(of: "<lab>").location, "<")]
        {
            #expect(editor.displayedCharacter(at: offset) == "\u{200B}", "\(name) is concealed")
            #expect((editor.characterRect(at: offset)?.width ?? 1) < 0.01, "\(name) takes no width")
        }
        let font = try #require(editor.drawnAttribute(.font, at: star + 1) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let heading = try #require(editor.drawnAttribute(.font, at: 2) as? NSFont)
        #expect(heading.pointSize > app.workspace.fontSize)
        #expect(editor.displayedAttachment(at: text.range(of: "- item").location)?.label == "•")
        #expect(editor.string == source, "Concealment never touches the source")

        // Entering a construct reveals only that construct.
        editor.setSelectedRange(NSRange(location: star + 3, length: 0))
        await app.settle(editor)
        #expect(editor.displayedCharacter(at: star) == "*")
        #expect((editor.characterRect(at: star)?.width ?? 0) > 1)
        #expect(editor.displayedCharacter(at: underscore) == "\u{200B}")
        // Reading mode off shows plain source.
        app.workspace.styledSource = false
        await app.settle(editor)
        #expect(editor.displayedCharacter(at: underscore) == "_")
        app.workspace.styledSource = true
        await app.settle(editor)
        #expect(editor.displayedCharacter(at: underscore) == "\u{200B}")
    }

    @Test func chipsShowLabelsAndTheirFormWritesBackInOneUndo() async throws {
        let source = """
        #let status(s) = {
          let (label, color) = (todo: ("待办", gray), done: ("已完成", green)).at(s)
          label
        }
        #let item(id, title, s, source: "你") = [#id #title #status(s)]

        #item("LB-001", "标题", "todo")

        End

        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let editor = try #require(app.workspace.editor)
        let session = try #require(editor.session)
        let call = (source as NSString).range(of: "#item(\"LB-001\"").location
        editor.setSelectedRange(NSRange(location: (source as NSString).length - 1, length: 0))
        await app.settle(editor)
        #expect(editor.displayedAttachment(at: call)?.label == "LB-001 标题 [待办]")
        let chip = try #require(session.chip(at: call))
        let fields = try ChipForm.fields(
            chip: chip,
            signature: #require(session.signature(for: chip)),
            formatter: session.formatter,
        )
        #expect(fields.map(\.name) == ["id", "title", "s", "source"])
        #expect(fields[2].choices?.map(\.label) == ["待办", "已完成"])
        #expect(fields[3].value == "你")

        // A click on the chip opens its form without moving the caret.
        await app.layout()
        editor.prepareForPointerInteraction()
        let box = try #require(boxViews(in: editor).first)
        let selection = editor.selectedRange()
        try box.mouseDown(with: #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        )))
        #expect(editor.chipPopover?.isShown == true)
        #expect(editor.selectedRange() == selection)
        editor.chipPopover?.close()

        let replacement = try #require(try session.edit(chip, values: ["s": "done"]))
        editor.applyReplacement(replacement, actionName: "Edit Call")
        #expect(editor.string.contains("#item(\"LB-001\", \"标题\", \"done\")"))
        #expect(app.workspace.text == editor.string)
        await app.settle(editor)
        #expect(editor.displayedAttachment(at: call)?.label == "LB-001 标题 [已完成]")
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(throws: ChipEditing.Failure.self) { try session.edit(chip, values: ["missing": "x"]) }
    }

    @Test func repeatPreviousCallInsertsTheCallWithTabPlaceholders() async throws {
        let source = "#let item(id, title, s) = [#id #title]\n\n#item(\"LB-001\", \"标题\", \"todo\")\n\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let end = (source as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        await app.settle(editor)
        await editor.repeatPreviousCall()
        #expect(editor.string == source + "#item(\"\", \"\", \"\")")
        #expect(editor.selectedRange() == NSRange(location: end + 7, length: 0))
        editor.keyDown(with: app.key("\t", code: 48))
        #expect(editor.selectedRange() == NSRange(location: end + 11, length: 0))
        editor.undoManager?.undo()
        #expect(editor.string == source)
    }

    @Test func inlineImagesDecodeOffTheMainThreadWithinBoundedSizes() async throws {
        let source = "#image(\"small.png\")\n\n#image(\"wide.png\")\n\n#image(\"missing.png\")\n\nEnd\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        try png(width: 40, height: 20).write(to: app.root.appendingPathComponent("small.png"))
        try png(width: 4000, height: 100).write(to: app.root.appendingPathComponent("wide.png"))
        let editor = try #require(app.workspace.editor)
        editor.load(source, selection: NSRange(location: (source as NSString).length - 1, length: 0))
        let wide = (source as NSString).range(of: "#image(\"wide").location
        let missing = (source as NSString).range(of: "#image(\"missing").location
        try await app.wait {
            editor.displayedAttachment(at: 0)?.size == CGSize(width: 40, height: 20)
                && editor.displayedAttachment(at: wide)?.size.width == InlineImageCache.maximumSize.width
        }
        #expect(editor.displayedAttachment(at: wide)?.size.height == 12)
        #expect(editor.displayedAttachment(at: missing)?.label == "missing.png")
    }

    @Test func equationsShowSourceUntilTheEngineTypesetsThem() async throws {
        let source = "Inline $x^2$ math.\n\nEnd\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let session = try #require(editor.session)
        let dollar = (source as NSString).range(of: "$x").location
        editor.setSelectedRange(NSRange(location: (source as NSString).length - 1, length: 0))
        await app.settle(editor)
        session.mathRenderer = nil
        await app.settle(editor)
        #expect(editor.displayedCharacter(at: dollar) == "$")
        let renderer = FixedMathRenderer()
        session.mathRenderer = renderer
        try await app.wait { editor.displayedAttachment(at: dollar)?.size == CGSize(width: 20, height: 10) }
        #expect(editor.displayedAttachment(at: dollar)?.label == "equation")
        #expect(renderer.batches.first?.first?.source == "$x^2$")
        editor.setSelectedRange(NSRange(location: dollar + 2, length: 0))
        await app.settle(editor)
        #expect(editor.displayedCharacter(at: dollar) == "$", "The caret reveals the equation's source")
    }

    @Test func equationsTypesetThroughTheEngineHelper() async throws {
        let source = "#set math.equation(numbering: none)\nInline $x^2 + y$ math.\n\nEnd\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        #expect(editor.session?.mathRenderer is EngineMathRenderer)
        let dollar = (source as NSString).range(of: "$x").location
        editor.setSelectedRange(NSRange(location: (source as NSString).length - 1, length: 0))
        await app.settle(editor)
        #expect(editor.session?.mathPreamble.contains("#set math.equation") == true)
        try await app.wait { editor.displayedAttachment(at: dollar)?.label == "equation" }
        let box = try #require(editor.displayedAttachment(at: dollar))
        #expect(box.size.width > 10 && box.size.height > 5)
        #expect(editor.string == source)
    }

    @Test func replansAboveADistantViewportWaitUntilItArrives() async throws {
        let body = String(repeating: "A long paragraph of plain words that fills the writing column.\n\n", count: 3000)
        let source = "Inline $x^2$ math.\n\n" + body + "End\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        let editor = try #require(app.workspace.editor)
        let session = try #require(editor.session)
        session.mathRenderer = nil
        let end = (source as NSString).length - 1
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.reveal(NSRange(location: end, length: 0))
        await app.settle(editor)
        let rebuilt = RebuiltRanges(editor)
        // Rebuilding text above a distant viewport makes macOS 15 lay out
        // the whole document to find the viewport again.
        session.mathRenderer = FixedMathRenderer()
        await app.settle(editor)
        #expect(!rebuilt.ranges.contains { $0.location == 0 }, "\(rebuilt.ranges)")
        editor.reveal(NSRange(location: 0, length: 0))
        try await app.wait { editor.displayedAttachment(at: 7)?.label == "equation" }
        #expect(rebuilt.ranges.contains { $0.location == 0 })
    }

    @Test func typingNeverWaitsForTheParser() async throws {
        let paragraph = "A paragraph with *strong* words and `code` that the plan conceals.\n\n"
        let source = String(repeating: paragraph, count: 4000)
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let middle = (source as NSString).length / 2
        editor.setSelectedRange(NSRange(location: middle, length: 0))
        await app.settle(editor)
        // An unclosed `$` reparses to the end of the document in the engine.
        var durations: [Duration] = []
        for character in "$ x + y" {
            let start = ContinuousClock.now
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            durations.append(start.duration(to: .now))
        }
        #expect(try #require(durations.max()) < .milliseconds(50), "\(durations)")
        await app.settle(editor)
        #expect(editor.string.utf16.count == source.utf16.count + 7)
    }
}

extension WritingFixture {
    /// Waits for the visual layer to plan the current text and selection.
    func settle(_ editor: ManuscriptTextView) async {
        await editor.session?.settled()
        await layout()
        editor.prepareForPointerInteraction()
    }
}

/// Attribute-only edits of an editor's text storage: paragraphs rebuilt.
@MainActor
final class RebuiltRanges: NSObject {
    private(set) var ranges: [NSRange] = []
    private weak var storage: NSTextStorage?

    init(_ editor: NSTextView) {
        storage = editor.textStorage
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(processed), name: NSTextStorage.didProcessEditingNotification, object: storage,
        )
    }

    @objc private func processed(_: Notification) {
        if let storage, !storage.editedMask.contains(.editedCharacters) {
            ranges.append(storage.editedRange)
        }
    }
}

/// Renders every equation as a 20 x 10 pt box after one batch.
final class FixedMathRenderer: InlineMathRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [MathRenderRequest: MathRenderResult] = [:]
    private(set) var batches: [[MathRenderRequest]] = []

    func render(_ requests: [MathRenderRequest]) -> [MathRenderResult] {
        let context = CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )
        let image = context?.makeImage().map { MathImage(image: $0, size: CGSize(width: 20, height: 10), baseline: 7) }
        let rendered = requests.map { MathRenderResult(request: $0, image: image, diagnostics: [], isStale: false) }
        lock.withLock {
            batches.append(requests)
            for result in rendered {
                results[result.request] = result
            }
        }
        return rendered
    }

    func cached(_ request: MathRenderRequest) -> MathRenderResult? {
        lock.withLock { results[request] }
    }
}

@MainActor
func boxViews(in view: NSView) -> [NSView] {
    view.subviews.flatMap { subview in
        String(describing: type(of: subview)) == "VisualBoxView" ? [subview] : boxViews(in: subview)
    }
}

func png(width: Int, height: Int) throws -> Data {
    let image = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
    ))
    return try #require(image.representation(using: .png, properties: [:]))
}
