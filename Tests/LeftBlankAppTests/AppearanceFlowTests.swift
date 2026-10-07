import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test func appearanceSwitchPersistsWithoutChangingWritingSelectionOrUndo() async throws {
        _ = NSApplication.shared
        let originalAppearance = NSApp.appearance
        let originalIcon = NSApp.applicationIconImage
        let dockIcon = DockIconController()
        #expect(dockIcon.isAvailable)
        defer {
            withExtendedLifetime(dockIcon) {}
            NSApp.appearance = originalAppearance
            NSApp
                .applicationIconImage = originalIcon
        }
        var icons: [AppAppearance: Data] = [:]
        let suite = "LeftBlank.appearance.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Keep this test independent of the user's app language and preferences.
        try defaults.set(
            JSONEncoder().encode(SyncedPreferences(language: L10n.language.rawValue)),
            forKey: LibraryPreferences.storageKey,
        )
        let source = "= A quiet page\n\n#let value = 42\n\nKeep 中文😀 intact.\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let settings = WorkspaceSettings(workspace: app.workspace, defaults: defaults)
        defer { settings.stop() }
        #expect(app.workspace.appearance == .system)
        #expect(NSApp.appearance == nil, "System mode must not pin the appearance at launch")
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(Snippet(text: "A new thought."), replacing: editor.selectedRange())
        editor.highlight()
        let text = editor.string
        let selection = editor.selectedRange()
        let revision = app.workspace.revision
        let origin = editor.enclosingScrollView?.contentView.bounds.origin
        let storage = try #require(editor.textStorage)
        let edits = AppearanceEditRecorder(storage)
        await app.settle(editor)
        // The heading's reading colour, drawn by the visual layer.
        let syntaxColor = try #require(editorColor(editor, at: (text as NSString).range(of: "quiet").location))
        let settingsView = NSHostingView(rootView: WritingSettingsView(
            workspace: app.workspace,
            library: app.workspace.library,
        ))
        settingsView.frame = NSRect(origin: .zero, size: WritingSettingsView.windowSize)
        settingsView.layoutSubtreeIfNeeded()
        #expect(settingsView.fittingSize.height > 0)

        for preference in [AppAppearance.light, .dark, .light] {
            app.workspace.appearance = preference
            await app.layout()
            try await app.wait { settings.preferences.values.appearance == preference.rawValue }
            let icon = try #require(NSApp.applicationIconImage?.tiffRepresentation)
            if let earlier = icons[preference] {
                #expect(icon == earlier)
            }
            icons[preference] = icon
            let appearance = editor.effectiveAppearance
            #expect(appearance.bestMatch(from: [.aqua, .darkAqua]) == (preference == .dark ? .darkAqua : .aqua))
            #expect(resolvedHex(editor.backgroundColor, appearance: appearance) ==
                (preference == .dark ? 0x1C1F23 : 0xFFFFFF))
            #expect(resolvedHex(Theme.sourceText, appearance: appearance) ==
                (preference == .dark ? 0xD5D9DE : 0x37474F))
            #expect(resolvedHex(syntaxColor, appearance: appearance) == (preference == .dark ? 0xEEE8DA : 0x263238))
            #expect(editor.string == text && app.workspace.text == text)
            #expect(editor.selectedRange() == selection)
            #expect(editor.enclosingScrollView?.contentView.bounds.origin == origin)
            #expect(editor.textStorage === storage)
            #expect(app.workspace.revision == revision)
            #expect(edits.characterEdits == 0, "Changing appearance must not replace the editor's source")
            #expect(LibraryPreferences(defaults: defaults).values.appearance == preference.rawValue)
            #expect(!app.workspace.previewDark, "Appearance is independent of preview document colors")
        }
        #expect(icons[.light] != icons[.dark], "The Dock must display different raster artwork in each appearance")
        editor.undoManager?.undo()
        #expect(editor.string == source && app.workspace.text == source)
        editor.undoManager?.redo()
        #expect(editor.string == text)

        // Simulate a live inherited appearance change without writing the user's
        // global macOS preference. AppKit delivers the same appearance callback.
        app.workspace.appearance = .system
        #expect(NSApp.appearance == nil)
        await app.layout()
        let inheritedIcon = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? AppAppearance
            .dark : .light
        #expect(NSApp.applicationIconImage?.tiffRepresentation == icons[inheritedIcon])
        for inherited in [NSAppearance.Name.darkAqua, .aqua] {
            app.window.appearance = NSAppearance(named: inherited)
            await app.layout()
            #expect(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == inherited)
            #expect(resolvedHex(editor.backgroundColor, appearance: editor.effectiveAppearance) ==
                (inherited == .darkAqua ? 0x1C1F23 : 0xFFFFFF))
            #expect(editor.string == text)
        }
        app.window.appearance = nil
        editor.setMarkedText(
            "输入",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: editor.selectedRange(),
        )
        let composition = editor.string
        app.workspace.appearance = .dark
        await app.layout()
        #expect(editor.hasMarkedText())
        #expect(editor.string == composition, "Appearance must preserve unfinished input-method composition")
        editor.unmarkText()
    }
}

@MainActor
func resolvedHex(_ color: NSColor, appearance: NSAppearance) -> UInt32 {
    var value: UInt32 = 0
    appearance.performAsCurrentDrawingAppearance {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return
        }
        value = UInt32((rgb.redComponent * 255).rounded()) << 16
            | UInt32((rgb.greenComponent * 255).rounded()) << 8
            | UInt32((rgb.blueComponent * 255).rounded())
    }
    return value
}

@MainActor
private final class AppearanceEditRecorder: NSObject {
    var characterEdits = 0
    init(_ storage: NSTextStorage) {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(record(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage,
        )
    }

    @objc private func record(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters)
        else {
            return
        }
        characterEdits += 1
    }
}
