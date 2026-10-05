import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import SwiftUI
import Testing
import UIKit

@MainActor
private final class AssistancePurchaseService: TabletPurchaseService {
    var access = SubscriptionAccess.subscribed(until: Date().addingTimeInterval(3600))
    func offering() -> SubscriptionOffering {
        .init(displayPrice: "$1", trialWeeks: nil)
    }

    func entitlement() -> SubscriptionAccess {
        access
    }

    func purchase() -> SubscriptionPurchaseResult {
        .cancelled
    }

    func restore() {}
    func manage(in scene: UIWindowScene) {}
    func updates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class AssistanceEditor: UITextView {
    let history = UndoManager()
    override var undoManager: UndoManager? {
        history
    }
}

@Suite(.serialized)
@MainActor
struct TabletAssistanceTests {
    private func fixture() async throws
        -> (TabletWorkspace, AssistanceEditor, AssistancePurchaseService, SourceCompletion)
    {
        let service = AssistancePurchaseService()
        let subscription = TabletSubscription(service: service)
        await subscription.refresh()
        let root = TestPaths.temporaryDirectory.appendingPathComponent("assistance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let editor = AssistanceEditor()
        workspace.editor = editor
        workspace.text = "#rec"
        workspace.activeSourceURL = URL(fileURLWithPath: "/completion-fixture.typ")
        workspace.selection = NSRange(location: 4, length: 0)
        editor.text = workspace.text
        editor.selectedRange = workspace.selection
        let response: JSONValue = .array([.object([
            "label": .string("rect()"), "textEdit": .object([
                "newText": .string("rect()"), "range": .object([
                    "start": .object(["line": .number(0), "character": .number(1)]),
                    "end": .object(["line": .number(0), "character": .number(4)]),
                ]),
            ]),
        ])])
        let completion = try #require(LanguageAssistance.completions(
            response,
            source: workspace.text,
            selection: workspace.selection,
        ).first)
        workspace.assistance.snapshot = try .init(
            source: workspace.text,
            url: #require(workspace.sourceURL),
            version: workspace.version,
            generation: workspace.generation,
            selection: workspace.selection,
        )
        workspace.assistance.completions = [completion]
        return (workspace, editor, service, completion)
    }

    @Test func completionUpdatesModelAndUndoesAsOneEdit() async throws {
        let (workspace, editor, _, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        editor.history.beginUndoGrouping()
        workspace.applyCompletion(completion)
        editor.history.endUndoGrouping()
        #expect(workspace.text == "#rect()")
        #expect(editor.text == workspace.text)
        #expect(workspace.selection == NSRange(location: 7, length: 0))
        #expect(editor.history.canUndo)
        editor.history.undo()
        #expect(workspace.text == "#rec")
        #expect(workspace.selection == NSRange(location: 4, length: 0))
        #expect(editor.text == workspace.text)
    }

    @Test func completionRejectsMovedCaretAndReplacedSession() async throws {
        let (workspace, editor, _, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        workspace.selection = NSRange(location: 0, length: 0)
        workspace.applyCompletion(completion)
        #expect(workspace.text == "#rec" && editor.text == "#rec")
        workspace.selection = NSRange(location: 4, length: 0)
        workspace.generation = UUID()
        workspace.applyCompletion(completion)
        #expect(workspace.text == "#rec" && editor.text == "#rec")
        #expect(!editor.history.canUndo)
    }

    @Test func completionRejectsExpiredAccessAfterResultsArrive() async throws {
        let (workspace, editor, service, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        service.access = .expired
        await workspace.subscription.refresh()
        workspace.applyCompletion(completion)
        #expect(workspace.text == "#rec" && editor.text == "#rec")
        #expect(workspace.panel == .subscription)
        #expect(!editor.history.canUndo)
    }

    @Test func embeddedHelpActionsDefinitionAndPreviewUseCurrentSource() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer {
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        let source = "#let answer = 42\n#answer\n#rect(width: 20pt, height: 30pt)\n== Heading\n"
        let document = try await workspace.library.create(text: source)
        // The fixture has no document yet; opening must not try to save its synthetic completion URL.
        workspace.activeSourceURL = nil
        await workspace.open(document)
        #expect(workspace.serviceReady)
        let keyboard = TabletTextView()
        keyboard.workspace = workspace
        func invoke(_ name: String) throws {
            let key = try #require(keyboard.keyCommands?.first { $0.action.map(NSStringFromSelector) == name })
            let action = try #require(key.action)
            #expect(keyboard.canPerformAction(action, withSender: key))
            keyboard.perform(action)
        }
        func select(_ line: Int, _ character: Int) {
            let offset = TextPosition(line: line, character: character).offset(in: workspace.text)
            workspace.selection = NSRange(location: offset, length: 0)
            editor.selectedRange = workspace.selection
        }
        select(2, 3)
        try invoke("explainSource")
        await workspace.assistance.task?.value
        #expect(workspace.assistance.hover?.text.lowercased().contains("rectangle") == true)
        select(2, 12)
        try invoke("explainSource")
        await workspace.assistance.task?.value
        #expect(workspace.assistance.signature?.activeParameter == "width:")
        select(3, 4)
        try invoke("sourceActions")
        await workspace.assistance.task?.value
        let action = try #require(workspace.assistance.actions.first { $0.title == "Increase depth of heading" })
        editor.history.beginUndoGrouping()
        workspace.applyContextAction(action)
        editor.history.endUndoGrouping()
        #expect(workspace.text.contains("\n=== Heading\n"))
        editor.history.undo()
        #expect(workspace.text == source)
        select(1, 3)
        let origin = workspace.selection
        try invoke("definition")
        await workspace.assistance.task?.value
        #expect(workspace.navigationHistory.count == 1)
        #expect(workspace.selection.location < origin.location)
        try invoke("back")
        for _ in 0 ..< 100 where !workspace.navigationHistory.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.navigationHistory.isEmpty)
        #expect(workspace.selection == origin)
        workspace.previewReady = false
        workspace.layout = .writing
        workspace.revealPreview()
        #expect(workspace.assistance.pendingPreview != nil)
        #expect(workspace.layout == .preview)
        workspace.previewReady = true
        workspace.serviceStatus = "Ready"
        workspace.sendPendingPreviewNavigation()
        #expect(workspace.assistance.pendingPreview == nil)
        workspace.previewReady = false
        workspace.revealPreview()
        workspace.version += 1
        workspace.sendPendingPreviewNavigation()
        #expect(workspace.assistance.pendingPreview == nil)
        workspace.layout = .writing
        workspace.replace("#rec")
        editor.selectedRange = NSRange(location: 4, length: 0)
        workspace.selection = editor.selectedRange
        try invoke("completeSource")
        await workspace.assistance.task?.value
        #expect(workspace.assistance.completions.contains { $0.label.hasPrefix("rect") })
    }

    @Test func nativeSelectAllReplacesTheCompleteDocumentInBothLayouts() async throws {
        let (workspace, _, _, _) = try await fixture()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let keyboard = TabletTextView()
        let coordinator = TabletEditor.Coordinator(workspace)
        keyboard.workspace = workspace
        keyboard.delegate = coordinator
        workspace.editor = keyboard
        controller.view.addSubview(keyboard)
        window.makeKeyAndVisible()
        defer {
            keyboard.typingTask?.cancel()
            workspace.generation = UUID()
            keyboard.resignFirstResponder()
            window.isHidden = true
            previous?.makeKey()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        for layout in [TabletWorkspace.Layout.writing, .split] {
            workspace.layout = layout
            keyboard.frame = CGRect(x: 0, y: 0, width: layout == .writing ? 600 : 300, height: 500)
            keyboard.text = "= Original\n中文😀 and a second line.\n"
            workspace.text = keyboard.text
            keyboard.becomeFirstResponder()
            keyboard.selectAll(nil)
            #expect(keyboard.selectedRange == NSRange(location: 0, length: keyboard.text.utf16.count))
            keyboard.insertText("= Replacement\nA complete document.\n")
            #expect(keyboard.text == "= Replacement\nA complete document.\n")
            #expect(workspace.text == keyboard.text)
            #expect(workspace.selection == keyboard.selectedRange)
        }
    }

    @Test func inlineCompletionKeyboardDoesNotReplaceMarkedTextAndEscapeCancels() async throws {
        let (workspace, editor, _, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        let keyboard = TabletTextView()
        keyboard.workspace = workspace
        keyboard.text = workspace.text
        keyboard.selectedRange = workspace.selection
        keyboard.presentTypingAssistance([completion], signature: nil, prefix: "rec")
        #expect(keyboard.typingOverlay != nil)
        let tab = try #require(keyboard.keyCommands?.first {
            $0.input == "\t" && $0.action.map(NSStringFromSelector) == "acceptTypingFromKeyboard"
        })
        #expect(tab.wantsPriorityOverSystemBehavior)
        editor.history.beginUndoGrouping()
        keyboard.acceptTypingFromKeyboard()
        editor.history.endUndoGrouping()
        #expect(workspace.text == "#rect()")
        editor.history.undo()
        #expect(workspace.text == "#rec")
        keyboard.presentTypingAssistance([completion], signature: nil, prefix: "rec")
        keyboard.dismissTypingFromKeyboard()
        #expect(keyboard.typingOverlay == nil)
        #expect(workspace.assistance.snapshot == nil)
        keyboard.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        keyboard.scheduleTypingAssistance()
        #expect(keyboard.typingTask == nil)
        #expect(keyboard.typingOverlay == nil)
        let commands = try #require(keyboard.keyCommands)
        #expect(!commands.contains { $0.action.map(NSStringFromSelector) == "acceptTypingFromKeyboard" })
        keyboard.unmarkText()
    }

    @Test func escapeIsBoundOnlyWhileSuggestionsAreVisible() async throws {
        let (workspace, _, _, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        let keyboard = TabletTextView()
        keyboard.workspace = workspace
        keyboard.text = workspace.text
        keyboard.selectedRange = workspace.selection
        func escapeBound() -> Bool {
            keyboard.keyCommands?
                .contains { $0.action.map(NSStringFromSelector) == "dismissTypingFromKeyboard" } == true
        }
        keyboard.scheduleTypingAssistance()
        workspace.assistance.kind = .completion
        workspace.assistance.loading = true
        #expect(keyboard.typingTask != nil)
        #expect(!escapeBound())
        #expect(!keyboard.canPerformAction(NSSelectorFromString("dismissTypingFromKeyboard"), withSender: nil))
        keyboard.cancelPendingTypingAssistance()
        #expect(keyboard.typingTask == nil)
        #expect(!workspace.assistance.loading)
        keyboard.presentTypingAssistance([completion], signature: nil, prefix: "rec")
        #expect(escapeBound())
        keyboard.dismissTypingFromKeyboard()
        #expect(!escapeBound())
    }

    @Test func embeddedTypingCompletionAndMultilineParameterHelpStayInline() async throws {
        let (workspace, _, _, _) = try await fixture()
        defer {
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let document = try await workspace.library.create(text: "#rec")
        await workspace.open(document)
        let keyboard = TabletTextView()
        keyboard.workspace = workspace
        keyboard.text = workspace.text
        keyboard.selectedRange = NSRange(location: 4, length: 0)
        workspace.editor = keyboard
        workspace.selection = keyboard.selectedRange
        workspace.assistance.onInvalidate = { [weak keyboard] in keyboard?.dismissTypingAssistance() }
        workspace.requestTypingAssistance(automatic: true)
        await workspace.assistance.task?.value
        #expect(keyboard.typingList.items.contains { $0.label.hasPrefix("rect") })
        #expect(workspace.panel == nil)
        #expect(workspace.text == "#rec")
        let source = "#rect(\n  width: 20pt)"
        workspace.replace(source)
        keyboard.text = source
        workspace.selection = NSRange(location: (source as NSString).range(of: "20pt").location, length: 0)
        keyboard.selectedRange = workspace.selection
        workspace.requestTypingAssistance(automatic: true)
        await workspace.assistance.task?.value
        #expect(keyboard.typingSignature?.activeParameter == "width:")
        #expect(keyboard.typingOverlay != nil)
        #expect(workspace.panel == nil)
        workspace.requestTypingAssistance(automatic: true)
        workspace.selection = NSRange(location: 0, length: 0)
        await workspace.assistance.task?.value
        #expect(workspace.assistance.snapshot == nil)
        workspace.layout = .split
        workspace.previewReady = false
        workspace.previewReading.followsWriting = true
        workspace.selection = NSRange(location: 2, length: 0)
        await workspace.previewFollowTask?.value
        #expect(workspace.assistance.pendingPreview?.selection == workspace.selection)
        #expect(workspace.followingPreviewNavigation)
        TabletPreview.Coordinator(workspace).receiveReading(["kind": "manualScroll"])
        workspace.previewReady = true
        workspace.serviceStatus = "Ready"
        workspace.sendPendingPreviewNavigation()
        #expect(!workspace.previewReading.followsWriting)
        #expect(workspace.assistance.pendingPreview == nil)
    }

    @Test func projectImportRequiresAnEntryAndRejectsPathsOutsideTheProject() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer {
            withExtendedLifetime(editor) {}
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let folder = workspace.stateDirectory.appendingPathComponent("Import")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = folder.appendingPathComponent("book.typ")
        let chapter = folder.appendingPathComponent("chapter.typ")
        try Data("#include \"chapter.typ\"".utf8).write(to: entry)
        try Data("A chapter".utf8).write(to: chapter)
        await workspace.importProject(folder)
        #expect(workspace.panel == .projectEntry)
        #expect(workspace.importSources == [entry, chapter])
        #expect(workspace.importSourceLabel(entry) == "book.typ")
        workspace.cancelProjectImport()
        #expect(workspace.importSources.isEmpty)
        #expect(workspace.importSourceLabel(entry) == "book.typ")
        await workspace.importProject(folder)
        await workspace.finishProjectImport(workspace.stateDirectory.appendingPathComponent("outside.typ"))
        #expect(workspace.document == nil)
        #expect(workspace.message != nil)
        await workspace.importProject(folder)
        await workspace.finishProjectImport(entry)
        #expect(workspace.entryURL?.lastPathComponent == "book.typ")
        #expect(workspace.text == "#include \"chapter.typ\"")
        #expect(workspace.importSources.isEmpty && workspace.panel == nil)
        #expect(workspace.serviceReady)
    }
}

extension TabletAssistanceTests {
    @Test func helpExamplesRenderWithTheEmbeddedEngineAndKeepTheManuscript() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer { workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let source = "#align(center)[Hi]"
        let document = try await workspace.library.create(title: "Examples", text: source)
        await workspace.open(document)
        workspace.selection = NSRange(location: 3, length: 0)
        editor.selectedRange = workspace.selection
        let selection = workspace.selection, preview = workspace.previewURL
        workspace.requestAssistance(.help)
        await workspace.assistance.task?.value
        let example = try #require(workspace.assistance.hover?.example)
        let root = workspace.stateDirectory.appendingPathComponent("HoverExamples")
        let image = try #require(await workspace.exampleRenderer.image(
            for: example, directory: root, packageCache: workspace.packageCache,
        ))
        #expect(image.size.width > 0 && image.size.height > 0)
        let bitmap = try #require(image.cgImage)
        let context = try #require(CGContext(
            data: nil,
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(
            (0 ..< bitmap.width * bitmap.height).contains { pixels[$0 * 4] < 200 },
            "The thumbnail must contain rendered ink, not an empty white page",
        )
        #expect(workspace.selection == selection && workspace.text == source)
        #expect(workspace.previewURL == preview && workspace.serviceReady)
        #expect(try DocumentStorage.read(document.sourceURL).0 == source)
        func exampleFor(_ code: String, suffix: String = "") throws -> HoverExample {
            try #require(LanguageAssistance.hover(.object([
                "contents": .string("```typ\n\(code)\n```\n" + suffix),
            ]))?.example)
        }
        let codeOnly = try exampleFor("#align(center)[Hi]")
        let rendered = try #require(await workspace.exampleRenderer.image(
            for: codeOnly, directory: root, packageCache: workspace.packageCache,
        ))
        #expect(await workspace.exampleRenderer.image(
            for: codeOnly, directory: root, packageCache: workspace.packageCache,
        ) === rendered)
        let svg = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\"/></svg>"
                .utf8,
        )
        let illustrated = try exampleFor(
            "#missing()",
            suffix: "<img src=\"data:image/svg+xml;base64,\(svg.base64EncodedString())\"/>",
        )
        #expect(await workspace.exampleRenderer.image(
            for: illustrated, directory: root, packageCache: workspace.packageCache,
        ) != nil)
        try Data("Private manuscript".utf8).write(to: root.appendingPathComponent("secret.txt"))
        #expect(try await workspace.exampleRenderer.image(
            for: exampleFor("#read(\"../secret.txt\")"),
            directory: root,
            packageCache: workspace.packageCache,
        ) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("secret.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func externalDefinitionsAreReadOnlyAndCloseReturnsToTheProject() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer { workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let source = "#import \"@preview/cetz:0.5.2\": canvas\n#canvas({})"
        let document = try await workspace.library.create(title: "Packages", text: source)
        await workspace.open(document)
        let origin = NSRange(location: (source as NSString).range(of: "#canvas").location + 2, length: 0)
        workspace.selection = origin
        editor.selectedRange = origin
        workspace.goToDefinition()
        await workspace.assistance.task?.value
        #expect(workspace.isPackageSource)
        #expect(!workspace.canEditSource && !editor.isEditable)
        #expect(workspace.entryURL == document.sourceURL && workspace.serviceReady)
        let packageURL = try #require(workspace.sourceURL)
        let original = try DocumentStorage.read(packageURL).0
        workspace.edited("Changed package", selection: .init(location: 0, length: 0))
        #expect(workspace.text == original)
        workspace.text = "Changed package"
        #expect(await workspace.save() == false)
        #expect(try DocumentStorage.read(packageURL).0 == original)
        workspace.text = original
        await workspace.closeSource()
        #expect(workspace.sourceURL == document.sourceURL && workspace.selection == origin)
        #expect(workspace.canEditSource && workspace.text == source && workspace.serviceReady)
        let keyboard = TabletTextView()
        keyboard.workspace = workspace
        let command = try #require(keyboard.keyCommands?.first { $0.input == "w" && $0.modifierFlags == .command })
        #expect(try keyboard.canPerformAction(#require(command.action), withSender: command))
        await workspace.closeSource()
        #expect(workspace.document == nil && workspace.sourceURL == nil)
        #expect(try DocumentStorage.read(document.sourceURL).0 == source)
    }

    @Test func localImportsAliasesAndIncludesNavigateWithoutChangingTheEntry() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer {
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let source = "#import \"module.typ\" as utils\n#utils.greet()\n#include \"chapter.typ\""
        let document = try await workspace.library.create(title: "Modules", text: source)
        let module = document.folderURL.appendingPathComponent("module.typ")
        let chapter = document.folderURL.appendingPathComponent("chapter.typ")
        try Data("#let greet() = [Hello]".utf8).write(to: module)
        try Data("A chapter".utf8).write(to: chapter)
        await workspace.open(document)
        for (token, target) in [("module.typ", module), ("greet", module), ("chapter.typ", chapter)] {
            let origin = NSRange(location: (source as NSString).range(of: token).location + 2, length: 0)
            workspace.selection = origin
            editor.selectedRange = origin
            workspace.goToDefinition()
            await workspace.assistance.task?.value
            #expect(workspace.sourceURL == target)
            #expect(workspace.entryURL == document.sourceURL && workspace.canEditSource)
            await workspace.closeSource()
            #expect(workspace.sourceURL == document.sourceURL && workspace.selection == origin)
        }
        let outside = workspace.stateDirectory.appendingPathComponent("outside.typ")
        try Data("Outside project".utf8).write(to: outside)
        #expect(await workspace.openSource(outside) == false)
        #expect(workspace.sourceURL == document.sourceURL)
    }

    @Test func pointerHelpPreservesSelectionAndClosesOnScroll() async throws {
        let (workspace, _, _, _) = try await fixture()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: TabletEditor(workspace: workspace))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            (workspace.editor as? TabletTextView)?.sourceHover.dismiss()
            workspace.client.stop()
            window.isHidden = true
            previous?.makeKey()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let source = "#align(center)[Hi]\n" + String(repeating: "Writing.\n", count: 100)
        let document = try await workspace.library.create(title: "Pointer", text: source)
        await workspace.open(document)
        workspace.layout = .writing
        try await waitFor { workspace.editor is TabletTextView }
        let editor = try #require(workspace.editor as? TabletTextView)
        try await waitFor { editor.isEditable && editor.text == source }
        try #require(editor.becomeFirstResponder())
        controller.view.layoutIfNeeded()
        editor.scrollRangeToVisible(NSRange(location: 2, length: 1))
        let selection = editor.selectedRange
        let start = try #require(editor.position(from: editor.beginningOfDocument, offset: 2))
        let end = try #require(editor.position(from: start, offset: 1))
        let rect = try editor.firstRect(for: #require(editor.textRange(from: start, to: end)))
        let point = CGPoint(x: rect.midX, y: rect.midY)
        #expect(editor.sourceHover.offset(at: point) == 2)
        editor.sourceHover.move(to: point)
        try await waitFor { editor.sourceHover.host != nil }
        #expect(editor.selectedRange == selection && workspace.text == source)
        #expect(editor.isFirstResponder)
        let host = try #require(editor.sourceHover.host)
        let parent = try #require(host.view.superview)
        let anchor = editor.convert(rect, to: parent)
        #expect(!host.view.frame.intersects(anchor))
        #expect(min(abs(host.view.frame.maxY - anchor.minY), abs(host.view.frame.minY - anchor.maxY)) <= 9)
        if let example = host.rootView.help.example {
            _ = await workspace.exampleRenderer.image(
                for: example,
                directory: workspace.stateDirectory.appendingPathComponent("HoverExamples"),
                packageCache: workspace.packageCache,
            )
        }
        window.layoutIfNeeded()
        let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try Attachment.record(#require(capture.pngData()), named: "iPad-pointer-hover.png")
        editor.setContentOffset(CGPoint(x: 0, y: editor.contentOffset.y + 40), animated: false)
        #expect(editor.sourceHover.host == nil)
    }

    private func waitFor(
        sourceLocation: Testing.SourceLocation = #_sourceLocation,
        _ condition: () -> Bool,
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}
