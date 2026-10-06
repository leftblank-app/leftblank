import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test func languageSwitchUpdatesExistingCommandsAndPreservesTheDocument() async throws {
        let originalLanguage = L10n.language
        let originalPreference = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        let localization = AppLocalization.shared
        defer {
            localization.select(originalLanguage)
            if let originalPreference {
                UserDefaults.standard.set(originalPreference, forKey: L10n.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
            }
        }
        let app = try WritingFixture(text: "= My own words\n\nKeep 中文😀 unchanged.\n", startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.insertSnippet(
            Snippet(text: "A thought.\n"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let original = editor.string
        let table = try #require(WritingCommand.all.first { $0.id == "table" })
        let englishResults = WritingCommand.search("table").map(\.id)
        localization.select(.english)
        #expect(localization.language == .english)
        #expect(table.title == "Table")
        #expect(table.fields[0].title == "Columns · 1–8")
        #expect(table.example?.contains("Heading 1") == true)
        func fieldLabels(_ view: NSView?) -> [String] {
            guard let view else {
                return []
            }
            return (view as? FocusTextField).flatMap { $0.accessibilityLabel() }.map { [$0] } ?? view.subviews
                .flatMap { fieldLabels($0) }
        }
        app.workspace.togglePalette()
        app.workspace.selectCommand(table)
        try await app.wait {
            app.window.contentView?.layoutSubtreeIfNeeded()
            return fieldLabels(app.window.contentView).contains("Columns · 1–8")
        }
        localization.select(.simplifiedChinese)
        try await app.wait {
            app.window.contentView?.layoutSubtreeIfNeeded()
            return fieldLabels(app.window.contentView).contains("列数 · 1–8")
        }
        #expect(localization.language == .simplifiedChinese)
        #expect(UserDefaults.standard.string(forKey: L10n.preferenceKey) == "zh-Hans")
        #expect(table.title == "表格")
        #expect(table.fields[0].title == "列数 · 1–8")
        #expect(table.example?.contains("标题 1") == true)
        #expect(WritingCommand.search("table").map(\.id) == englishResults)
        #expect(WritingCommand.search("表格").contains { $0.id == "table" })
        #expect(CommandGroup.roots.first?.title == "插入内容")
        #expect(L10n.format("%@ commands", "106") == "106 个命令")
        #expect(editor.string == original)
        #expect(app.workspace.text == original)
        #expect(editor.undoManager?.canUndo == true)
        let settings = NSHostingView(rootView: WritingSettingsView(
            workspace: app.workspace,
            library: app.workspace.library,
        ))
        settings.frame = NSRect(origin: .zero, size: WritingSettingsView.windowSize)
        settings.layoutSubtreeIfNeeded()
        #expect(settings.fittingSize.height > 0)
        localization.select(.english)
        #expect(CommandGroup.roots.first?.title == "Insert")
        #expect(editor.string == original)
    }
}
