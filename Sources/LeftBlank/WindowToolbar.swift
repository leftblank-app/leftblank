import AppKit
import Combine
import LeftBlankCore
import SwiftUI

@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    private let workspace: Workspace
    private let documentID = NSToolbarItem.Identifier("LeftBlankDocument")
    private let actionsID = NSToolbarItem.Identifier("LeftBlankActions")

    private let titleSize = ToolbarTitleSize()
    private var subscriptions: Set<AnyCancellable> = []

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        Publishers.CombineLatest3(workspace.$managedTitle, workspace.$fileURL, workspace.$isPackageSource)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.resizeTitle() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: workspace.window)
            .sink { [weak self] _ in self?.resizeTitle() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .leftblankLanguageChanged)
            .sink { [weak self] _ in self?.resizeTitle() }.store(in: &subscriptions)
        resizeTitle()
    }

    private func resizeTitle() {
        let textWidth = (workspace.title as NSString).size(withAttributes: [.font: NSFont.systemFont(
            ofSize: 12,
            weight: .medium,
        )]).width
        // Reserve traffic lights, native toolbar spacing and the fixed actions.
        // A short title hugs its content; long names can use the remaining space.
        let available = max(120, (workspace.window?.frame.width ?? 820) - 340)
        let badgeWidth = workspace.isPackageSource ?
            (L10n.text("Read-only") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
            .width + 36 : 0
        let width = min(available, max(160, ceil(textWidth + badgeWidth) + 64))
        if titleSize.width != width {
            titleSize.width = width
        }
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "LeftBlankToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [documentID, .flexibleSpace, actionsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool,
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == documentID {
            item.label = L10n.text("Current Document")
            item.view = NSHostingView(rootView: AdaptiveDocumentTitle(workspace: workspace, size: titleSize))
        } else if identifier == actionsID {
            item.label = L10n.text("Writing Views and Export")
            item.view = NSHostingView(rootView: WritingActions(workspace: workspace).frame(height: 30))
        } else {
            return nil
        }
        // AppKit adds Liquid Glass behind custom toolbar views on macOS 26,
        // independently of SwiftUI's button style. Keep both groups unframed.
        item.isBordered = false
        return item
    }
}

@MainActor
private final class ToolbarTitleSize: ObservableObject {
    @Published var width: CGFloat = 240
}

private struct AdaptiveDocumentTitle: View {
    let workspace: Workspace
    @ObservedObject var size: ToolbarTitleSize
    var body: some View {
        DocumentTitle(workspace: workspace).frame(width: size.width, height: 30)
    }
}

private struct DocumentTitle: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        HStack(spacing: 8) {
            QuietButton(icon: "files", help: L10n.text("Your writing"), shortcut: "⌘O") { workspace.openLibrary() }
                .accessibilityIdentifier("toolbar.library")
            if workspace.isPackageSource {
                Text(workspace.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(workspace.fileURL?.path ?? workspace.title)
                ReadOnlyPackageBadge()
            } else {
                EditableDocumentName(
                    title: workspace.title,
                    documentID: workspace.managedDocumentID,
                    onOpen: { workspace.openLibrary() },
                    onRename: { [id = workspace.managedDocumentID] title in
                        guard let id else {
                            return
                        }
                        workspace.library.perform { try await workspace.library.rename(id, title: title) }
                    },
                    onFinish: { workspace.editor?.window?.makeFirstResponder(workspace.editor) },
                )
                .frame(height: 16).frame(height: 30)
                .learningHelp(L10n.text("Click to rename. Double-click to open your writing."))
            }
            if workspace.text != workspace.savedText, workspace.fileURL != nil {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).accessibilityLabel(L10n.text("Unsaved"))
            }
        }.frame(height: 30).foregroundStyle(Theme.text)
    }
}

struct ReadOnlyPackageBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)
            Text(L10n.text("Read-only"))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.secondary.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border.opacity(0.7), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Read-only Package"))
        .accessibilityIdentifier("toolbar.read-only")
        .learningHelp(
            L10n.text("Read-only Package"),
            detail: L10n.text("You can view and copy package source. Save a copy to edit it."),
        )
    }
}

private struct WritingActions: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        HStack(spacing: 6) {
            QuietButton(
                icon: "pencil-simple",
                help: L10n.text("Focus on Writing"),
                shortcut: WritingCommand.all.first { $0.id == "writing" }?.shortcuts.first?.label,
                detail: L10n.text("A quiet space for your words."),
                active: workspace.layout == .writing,
            ) { workspace.layout = .writing }
            QuietButton(
                icon: "columns",
                help: L10n.text("Side-by-side Preview"),
                shortcut: WritingCommand.all.first { $0.id == "split" }?.shortcuts.first?.label,
                detail: L10n.text("Write on the left, see the live page on the right."),
                active: workspace.layout == .split,
            ) { workspace.layout = .split }
            QuietButton(
                icon: "eye",
                help: L10n.text("Read the Preview"),
                shortcut: WritingCommand.all.first { $0.id == "preview" }?.shortcuts.first?.label,
                detail: L10n.text("Fill the workspace with your finished pages."),
                active: workspace.layout == .preview,
            ) { workspace.layout = .preview }
            Rectangle().fill(Theme.border.opacity(0.65)).frame(width: 1, height: 12).padding(.horizontal, 5)
            QuietButton(
                icon: "arrow-square-out",
                help: L10n.text("Export PDF"),
                shortcut: WritingCommand.all.first { $0.id == "export" }?.shortcuts.first?.label,
                detail: L10n.text("Export the current document in its original colors."),
            ) { workspace.exportPDF() }.disabled(workspace.exporting)
        }.fixedSize().disabled(workspace.isLibraryHome)
    }
}
