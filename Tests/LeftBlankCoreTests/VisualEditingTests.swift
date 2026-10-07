import CoreGraphics
import Foundation
import ImageIO
@testable import LeftBlankCore
import Testing
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

// The shared visual layer, on a real TextKit 2 text view: NSTextView on the
// Mac, UITextView on the iPad (this suite also runs in the iPad test plan).

private let sample = """
#let status(s) = {
  let (label, color) = (todo: ("待办", gray), done: ("已完成", green)).at(s)
  label
}
#let item(id, title, s, source: "你") = [#id #title #status(s)]
= 第一章 Heading
Text *粗体 bold* and _emph_ with `code`, @intro and <lab>.
Before #item("LB-001", "标题", "todo") after chip.
- list item
Inline $x^2 + y$ math.

"""

@MainActor
private final class Harness {
    #if canImport(AppKit)
        let window: NSWindow
        let view: NSTextView
    #else
        let window: UIWindow
        let view: UITextView
    #endif
    let session: VisualEditorSession
    let manager: NSTextLayoutManager

    init(_ text: String = sample) throws {
        let style = VisualStyle(
            fontSize: 14, text: .black, strong: .black, code: .darkGray, codeBackground: .lightGray,
            link: .blue, marker: .gray, math: .brown, chip: .purple, chipFill: .lightGray,
        )
        #if canImport(AppKit)
            _ = NSApplication.shared
            window = NSWindow(
                contentRect: CGRect(x: -8000, y: -8000, width: 700, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false,
            )
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
            view = NSTextView(usingTextLayoutManager: true)
            view.frame = scroll.bounds
            view.isRichText = false
            view.allowsUndo = true
            view.isVerticallyResizable = true
            view.autoresizingMask = [.width]
            scroll.documentView = view
            window.contentView = scroll
            window.orderFrontRegardless()
            let content = try #require(view.textContentStorage)
        #else
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
            view = UITextView(usingTextLayoutManager: true)
            view.frame = window.bounds
            view.textContainerInset = .zero
            window.addSubview(view)
            window.isHidden = false
            let content = try #require(view.textLayoutManager?.textContentManager as? NSTextContentStorage)
        #endif
        manager = try #require(view.textLayoutManager)
        session = VisualEditorSession(contentStorage: content, textLayoutManager: manager, style: style)
        #if canImport(AppKit)
            view.string = text
        #else
            view.text = text
        #endif
        storage.setAttributes(style.baseAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        session.hasMarkedText = { [view] in Self.hasMarkedText(view) }
        forwarder = Forwarder(session: session)
        storage.delegate = forwarder
        session.open(selection: away)
        select(away)
    }

    private var forwarder: Forwarder?

    var away: NSRange {
        NSRange(location: string.length, length: 0)
    }

    var storage: NSTextStorage {
        #if canImport(AppKit)
            view.textStorage ?? NSTextStorage()
        #else
            view.textStorage
        #endif
    }

    var string: NSString {
        storage.string as NSString
    }

    func close() {
        #if canImport(AppKit)
            window.close()
        #else
            window.isHidden = true
        #endif
    }

    func select(_ range: NSRange) {
        #if canImport(AppKit)
            view.setSelectedRange(range)
        #else
            view.selectedRange = range
        #endif
        session.selectionDidChange(range)
    }

    func settle() async {
        await session.settled()
        manager.ensureLayout(for: manager.documentRange)
        manager.textViewportLayoutController.layoutViewport()
    }

    func width(_ range: NSRange) -> CGFloat {
        TextKit2Geometry.segments(range, type: .standard, in: manager).reduce(0) { $0 + $1.width }
    }

    /// The character laid out at `offset`.
    func displayed(_ offset: Int) -> String? {
        guard let location = TextKit2Geometry.location(offset, in: manager),
              let paragraph = manager.textLayoutFragment(for: location)?.textElement as? NSTextParagraph,
              let start = paragraph.elementRange?.location
        else {
            return nil
        }
        let local = offset - TextKit2Geometry.offset(of: start, in: manager)
        return (paragraph.attributedString.string as NSString).substring(with: NSRange(location: local, length: 1))
    }

    func attachment(_ offset: Int) -> VisualAttachment? {
        guard let location = TextKit2Geometry.location(offset, in: manager),
              let paragraph = manager.textLayoutFragment(for: location)?.textElement as? NSTextParagraph,
              let start = paragraph.elementRange?.location
        else {
            return nil
        }
        let local = offset - TextKit2Geometry.offset(of: start, in: manager)
        return paragraph.attributedString.attribute(.attachment, at: local, effectiveRange: nil) as? VisualAttachment
    }

    func replace(_ range: NSRange, with text: String) {
        #if canImport(AppKit)
            view.insertText(text, replacementRange: range)
        #else
            view.selectedRange = range
            view.insertText(text)
        #endif
    }

    func setMarkedText(_ text: String) {
        #if canImport(AppKit)
            view.setMarkedText(
                text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0),
            )
        #else
            view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        #endif
    }

    func commitMarkedText(_ text: String) {
        #if canImport(AppKit)
            view.insertText(text, replacementRange: view.markedRange())
        #else
            view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            view.unmarkText()
        #endif
    }

    static func hasMarkedText(_ view: PlatformTextView) -> Bool {
        #if canImport(AppKit)
            view.hasMarkedText()
        #else
            view.markedTextRange != nil
        #endif
    }

    var undoManager: UndoManager? {
        view.undoManager
    }
}

@MainActor
private final class Forwarder: NSObject, @preconcurrency NSTextStorageDelegate {
    let session: VisualEditorSession
    init(session: VisualEditorSession) {
        self.session = session
    }

    func textStorage(
        _: NSTextStorage,
        didProcessEditing editedMask: StorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int,
    ) {
        if editedMask.contains(.editedCharacters) {
            session.textDidChange(edited: editedRange, delta: delta)
        }
    }
}

@MainActor
@Suite(.serialized) struct VisualEditingTests {
    @Test func markersAreConcealedWithZeroWidthAndBoxesReplaceCalls() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let text = harness.string
        let star = text.range(of: "*粗体").location
        for offset in [star, text.range(of: "_emph").location, text.range(of: "`code").location,
                       text.range(of: "@intro").location, text.range(of: "= 第一章").location]
        {
            #expect(harness.displayed(offset) == "\u{200B}")
            #expect(harness.width(NSRange(location: offset, length: 1)) < 0.01)
        }
        let call = text.range(of: "#item(\"LB-001\"").location
        let chip = try #require(harness.attachment(call))
        #expect(chip.label == "LB-001 标题 [待办]")
        #expect(harness.displayed(call + 1) == "\u{200B}")
        #expect(harness.attachment(text.range(of: "- list").location)?.label == "•")
        #expect(harness.string == sample as NSString, "The source never changes")
        // Every visible character hit-tests back to itself.
        let line = text.range(of: "Text *粗体 bold*")
        for offset in line.location ..< NSMaxRange(line) where harness.width(NSRange(location: offset, length: 1)) > 1 {
            let frame = try #require(TextKit2Geometry.segments(
                NSRange(location: offset, length: 1), type: .standard, in: harness.manager,
            ).first)
            #expect(TextKit2Geometry.character(
                at: CGPoint(x: frame.minX + 1, y: frame.midY), in: harness.manager, text: text,
            ) == offset)
        }
    }

    @Test func enteringAConstructRevealsOnlyThatConstruct() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let text = harness.string
        let star = text.range(of: "*粗体").location
        harness.select(NSRange(location: star + 2, length: 0))
        await harness.settle()
        #expect(harness.displayed(star) == "*")
        #expect(harness.width(NSRange(location: star, length: 1)) > 1)
        #expect(harness.displayed(text.range(of: "_emph").location) == "\u{200B}")
        let call = text.range(of: "#item(\"LB-001\"").location
        harness.select(NSRange(location: call + 3, length: 0))
        await harness.settle()
        #expect(harness.attachment(call) == nil, "The caret in a call shows its source")
        #expect(harness.displayed(star) == "\u{200B}")
    }

    @Test func compositionDefersPlansAndUndoRestoresTheSource() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let text = harness.string
        let after = text.range(of: " after chip").location
        harness.select(NSRange(location: after, length: 0))
        await harness.settle()
        harness.setMarkedText("zhong")
        harness.select(harness.view.selectedRange)
        #expect(Harness.hasMarkedText(harness.view))
        harness.commitMarkedText("中")
        harness.select(harness.view.selectedRange)
        await harness.settle()
        #expect(harness.string.substring(with: NSRange(location: after, length: 1)) == "中")
        #expect(harness.attachment(text.range(of: "#item(\"LB-001\"").location)?.label == "LB-001 标题 [待办]")
        harness.undoManager?.undo()
        #expect(harness.string == sample as NSString)
    }

    @Test func formsWriteOneReplacementAndRepeatPreviousCopiesTheCall() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let text = harness.string
        let chip = try #require(harness.session.chip(at: text.range(of: "#item(\"LB-001\"").location))
        let signature = try #require(harness.session.signature(for: chip))
        let fields = ChipForm.fields(chip: chip, signature: signature, formatter: harness.session.formatter)
        #expect(fields.map(\.name) == ["id", "title", "s", "source"])
        #expect(fields[2].choices == [.init(value: "todo", label: "待办"), .init(value: "done", label: "已完成")])
        var edited = fields
        edited[2].value = "done"
        edited[3].value = "你"
        #expect(ChipForm.values(edited, chip: chip) == ["s": "done", "source": "你"])
        let replacement = try #require(try harness.session.edit(chip, values: ["s": "done"]))
        #expect(replacement.text == "\"done\"")
        let insertion = try #require(await harness.session.repeatPrevious(at: text.length))
        #expect(insertion.snippet.text == "#item(\"\", \"\", \"todo\")")
        #expect(insertion.snippet.selections.count == 2)
    }

    @Test func editsAreRebasedUntilTheEngineReplies() async throws {
        let harness = try Harness()
        defer { harness.close() }
        await harness.settle()
        let text = harness.string
        let emph = text.range(of: "_emph").location
        // Typing before a construct moves its concealment with it immediately.
        harness.replace(NSRange(location: 0, length: 0), with: "// new\n")
        #expect(harness.session.snapshot.length == harness.string.length)
        #expect(harness.session.snapshot.plan(in: NSRange(location: emph + 7, length: 1)).conceals
            .contains { $0.location == emph + 7 })
        await harness.settle()
        #expect(harness.displayed(emph + 7) == "\u{200B}")
    }
}

@Test func valueLabelsComeFromDictionariesAndForwardedParameters() throws {
    let text = sample as NSString
    let nodes = try #require(SyntaxTree(sample)?.nodes())
    let labels = Presentation.valueLabels(source: text, nodes: nodes)
    let expected: [ChipValueLabel] = [.init(value: "todo", label: "待办"), .init(value: "done", label: "已完成")]
    #expect(labels["status"]?["s"] == expected)
    #expect(labels["item"]?["s"] == expected)
    let formatter = ChipFormatter(functions: labels)
    let argument = ChipArgument(name: "s", isPositional: true, valueRange: NSRange(), literal: "done", isString: true)
    #expect(formatter.label(callee: "item", arguments: [argument]) == "[已完成]")
    #expect(formatter.labels(callee: "other", parameter: "s") == nil)
    let strings = "#let f(k) = (\"a\": \"Alpha\", \"b\": 2).at(k)\n"
    let simple = try Presentation.valueLabels(
        source: strings as NSString,
        nodes: #require(SyntaxTree(strings)?.nodes()),
    )
    #expect(simple["f"]?["k"] == [.init(value: "a", label: "Alpha"), .init(value: "b", label: "b")])
}

@Test func snapshotsRebaseEditsAndReportOnlyChangedEntries() throws {
    let source = "Text *one* and *two* here.\n\nNext _three_.\n" as NSString
    let tree = try #require(SyntaxTree(source as String))
    let store = PresentationStore(source: source, tree: tree, selection: NSRange(location: source.length, length: 0))
    var snapshot = store.snapshot
    let second = source.range(of: "*two*")
    // Entries the edit touches are dropped (the strong run around it);
    // entries before it stay and entries after it shift.
    snapshot.edit(NSRange(location: 7, length: 0), replacementLength: 2)
    let plan = snapshot.plan(in: NSRange(location: 0, length: snapshot.length))
    #expect(!plan.styles.contains { $0.range.location == 5 })
    #expect(plan.conceals.contains { $0.location == 5 } && plan.conceals.contains { $0.location == 11 })
    #expect(plan.conceals.contains { $0.location == second.location + 2 })
    #expect(snapshot.length == source.length + 2)
    #expect(store.snapshot.changedRanges(from: store.snapshot).isEmpty)
    var edited = store
    let updated = NSMutableString(string: source)
    updated.replaceCharacters(in: NSRange(location: 0, length: 0), with: "*")
    let reparsed = try #require(tree.edit(NSRange(location: 0, length: 0), replacement: "*"))
    edited.edit(NSRange(location: 0, length: 0), replacementLength: 1, reparsed: reparsed, source: updated, tree: tree)
    var rebased = store.snapshot
    rebased.edit(NSRange(location: 0, length: 0), replacementLength: 1)
    let changed = edited.snapshot.changedRanges(from: rebased)
    #expect(!changed.isEmpty)
    #expect(changed.allSatisfy { $0.location < source.range(of: "Next").location })
}

@Test func theEngineMatchesAFreshPlanAfterSeededEditsAndSelections() async throws {
    let engine = PresentationEngine()
    var text = sample
    _ = await engine.open(text, selection: NSRange(location: 0, length: 0), options: PresentationOptions())
    var state: UInt64 = 7
    func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(1, bound)))
    }
    for _ in 0 ..< 60 {
        let length = (text as NSString).length
        var location = next(length + 1)
        location = (text as NSString).rangeOfComposedCharacterSequence(at: min(location, max(0, length - 1))).location
        let delete = min(next(3), length - location)
        let range = (text as NSString).rangeOfComposedCharacterSequences(for: NSRange(
            location: location,
            length: delete,
        ))
        let insert = ["*", "x", "\n", "`", "$", "中", "😀", "#item(\"a\", \"b\", \"done\")", ""][next(9)]
        text = (text as NSString).replacingCharacters(in: range, with: insert)
        let selection = NSRange(location: next((text as NSString).length + 1), length: 0)
        let reply = await engine.update([.init(range: range, text: insert)], selection: selection)
        let tree = try #require(SyntaxTree(text))
        var options = PresentationOptions()
        options.formatter.functions = Presentation.valueLabels(source: text as NSString, nodes: tree.nodes() ?? [])
        let fresh = PresentationStore(source: text as NSString, tree: tree, selection: selection, options: options)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        #expect(reply.snapshot.plan(in: whole) == fresh.snapshot.plan(in: whole))
    }
}

@Test func inlineImagesDecodeWithinBoundedSizes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func write(_ name: String, width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
    let small = try #require(try InlineImageCache.decode(write("small.png", width: 40, height: 20)))
    #expect(small.size == CGSize(width: 40, height: 20))
    let large = try #require(try InlineImageCache.decode(write("large.png", width: 6000, height: 3000)))
    #expect(large.size == CGSize(width: 480, height: 240))
    #expect(max(large.image.width, large.image.height) <= 960, "Decoding is bounded in pixels")
    #expect(InlineImageCache.decode(directory.appendingPathComponent("missing.png")) == nil)
}
