import AppKit
import Combine
import LeftBlankCore
import SwiftUI

public enum LeftBlankApplication {
    @MainActor public static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let workspace: Workspace
    private var window: NSWindow?
    private var windowToolbar: WindowToolbar?
    private var settingsWindow: NSWindow?
    private var settingsController: WorkspaceSettings?
    private var languageObserver: AnyCancellable?
    private var dockIcon: DockIconController?
    #if LEFTBLANK_PREVIEW
        private let previewUpdater = PreviewUpdater()
    #endif

    init(workspace: Workspace = Workspace()) {
        self.workspace = workspace
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsController = WorkspaceSettings(workspace: workspace)
        dockIcon = DockIconController()
        if dockIcon?.isAvailable == true {
            workspace.recordOperation("application.iconLoaded")
        }
        installMenu()
        let writingWindow = WritingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        writingWindow.workspace = workspace
        workspace.window = writingWindow
        window = writingWindow
        let window = writingWindow
        window.title = workspace.title + " — " + AppDistribution.current.applicationName
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        windowToolbar = WindowToolbar(workspace: workspace)
        window.toolbar = windowToolbar?.makeToolbar()
        window.backgroundColor = Theme.nativeBackground
        window.minSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(workspace: workspace))
        window.setFrameAutosaveName("LeftBlankMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        workspace
            .onTitleChange = { [weak self] title in
                self?.window?.title = title + " — " + AppDistribution.current.applicationName
            }
        workspace.onShortcutChange = { [weak self] in self?.installMenu() }
        languageObserver = NotificationCenter.default.publisher(for: .leftblankLanguageChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.installMenu()
                self?.settingsWindow?.title = L10n.text("Settings")
                if let self {
                    self.window?.title = workspace.title + " — " + AppDistribution.current.applicationName
                }
            }
        }
        workspace.startService()
        Task { await workspace.library.start() }
        NSApp.activate(ignoringOtherApps: true)
        #if LEFTBLANK_PREVIEW
            previewUpdater.start()
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.workspace.paletteOpen, let editor = workspace.editor else {
                return
            }
            self.window?.makeFirstResponder(editor)
        }
    }

    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window?.makeFirstResponder(nil)
        guard workspace.prepareToClose() else {
            return .terminateCancel
        }
        guard workspace.history.hasPendingWrites else {
            return .terminateNow
        }
        // Sparkle requests a normal NSApp termination. Failure to preserve writing cancels updates,
        // and pending history finishes before Sparkle can replace the app.
        // Autosave queues history off the main actor. Allow the final checkpoint
        // to finish before exiting, including a quit immediately after typing.
        Task { @MainActor in
            await workspace.history.drain()
            replyToTermination(true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        workspace.closeDocument()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsController?.stop()
        workspace.shutdown()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first {
            workspace.open(URL(fileURLWithPath: path))
        }
    }

    func installMenu() {
        let menu = NSMenu()
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            menu.addItem(item)
            item.submenu = submenu
            return submenu
        }
        func item(
            _ title: String,
            _ action: Selector,
            _ key: String,
            _ owner: NSMenu,
            modifiers: NSEvent.ModifierFlags = .command,
            target: AnyObject? = nil,
        ) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = target
            owner.addItem(entry)
        }
        func commandItem(_ id: String, in menu: NSMenu) {
            guard let command = WritingCommand.all.first(where: { $0.id == id })
            else {
                return
            }
            let shortcut = command.shortcuts.first
            let entry = NSMenuItem(
                title: command.title,
                action: #selector(runWritingCommand(_:)),
                keyEquivalent: shortcut?.key ?? "",
            )
            var flags: NSEvent.ModifierFlags = []
            if shortcut?.modifiers.contains(.command) == true {
                flags.insert(.command)
            }
            if shortcut?.modifiers.contains(.shift) == true {
                flags.insert(.shift)
            }
            if shortcut?.modifiers.contains(.option) == true {
                flags.insert(.option)
            }
            if shortcut?.modifiers.contains(.control) == true {
                flags.insert(.control)
            }
            entry.keyEquivalentModifierMask = flags
            entry.representedObject = id
            entry.target = self
            menu.addItem(entry)
        }
        let app = section(AppDistribution.current.applicationName)
        item(L10n.format("About %@", AppDistribution.current.applicationName), #selector(about), "", app, target: self)
        #if LEFTBLANK_PREVIEW
            app.addItem(previewUpdater.makeCheckMenuItem())
            app.addItem(previewUpdater.makeAutomaticChecksMenuItem())
        #endif
        item(L10n.text("Settings…"), #selector(settings), ",", app, target: self)
        app.addItem(.separator())
        let services = NSMenu(title: L10n.text("Services"))
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        item(
            L10n.format("Hide %@", AppDistribution.current.applicationName),
            #selector(NSApplication.hide(_:)),
            "h",
            app,
        )
        item(
            L10n.text("Hide Others"),
            #selector(NSApplication.hideOtherApplications(_:)),
            "h",
            app,
            modifiers: [.command, .option],
        )
        item(L10n.text("Show All"), #selector(NSApplication.unhideAllApplications(_:)), "", app)
        app.addItem(.separator())
        item(
            L10n.format("Quit %@", AppDistribution.current.applicationName),
            #selector(NSApplication.terminate(_:)),
            "q",
            app,
        )
        let file = section(L10n.text("Documents"))
        item(L10n.text("New Document"), #selector(newDocument), "n", file, target: self)
        item(L10n.text("Your writing…"), #selector(openLibrary), "o", file, target: self)
        item(
            L10n.text("Import a document…"),
            #selector(importDocument),
            "o",
            file,
            modifiers: [.command, .shift],
            target: self,
        )
        item(L10n.text("Open external file…"), #selector(openDocument), "", file, target: self)
        file.addItem(.separator())
        item(L10n.text("Save"), #selector(saveDocument), "s", file, target: self)
        item(L10n.text("Save As…"), #selector(saveAs), "s", file, modifiers: [.command, .shift], target: self)
        item(L10n.text("Document History…"), #selector(documentHistory), "", file, target: self)
        item(L10n.text("Recover Draft Copy…"), #selector(recoverDraft), "", file, target: self)
        item(L10n.text("Export PDF…"), #selector(exportPDF), "e", file, modifiers: [.command, .shift], target: self)
        file.addItem(.separator())
        item(L10n.text("Print…"), #selector(printDocument), "p", file, target: self)
        file.addItem(.separator())
        item(L10n.text("Close Document"), #selector(NSWindow.performClose(_:)), "w", file)
        let edit = section(L10n.text("Edit"))
        item(L10n.text("Undo"), Selector(("undo:")), "z", edit)
        item(L10n.text("Redo"), Selector(("redo:")), "z", edit, modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(L10n.text("Cut"), #selector(NSText.cut(_:)), "x", edit)
        item(L10n.text("Copy"), #selector(NSText.copy(_:)), "c", edit)
        item(L10n.text("Paste"), #selector(NSText.paste(_:)), "v", edit)
        item(L10n.text("Select All"), #selector(NSText.selectAll(_:)), "a", edit)
        edit.addItem(.separator())
        item(L10n.text("Find…"), #selector(find), "f", edit, target: self)
        item(L10n.text("Complete Syntax"), #selector(completion), ".", edit, modifiers: .control, target: self)
        for id in [
            "quickHelp",
            "contextActions",
            "editObject",
            "definition",
            "navigateBack",
            "indent",
            "outdent",
            "comment",
            "format",
        ] {
            commandItem(id, in: edit)
        }
        let view = section(L10n.text("View"))
        item(L10n.text("Discover Commands"), #selector(palette), workspace.commandKey, view, target: self)
        item(L10n.text("Open Diagnostic Logs"), #selector(revealLogs), "", view, target: self)
        item(L10n.text("Focus on Writing"), #selector(writing), "1", view, target: self)
        item(L10n.text("Side-by-side Preview"), #selector(split), "2", view, target: self)
        item(L10n.text("Read the Preview"), #selector(preview), "3", view, target: self)
        for id in ["outline", "diagnostics", "universe"] {
            commandItem(id, in: view)
        }
        view.addItem(.separator())
        item(L10n.text("Increase Text Size"), #selector(increaseFont), "+", view, target: self)
        item(L10n.text("Decrease Text Size"), #selector(decreaseFont), "-", view, target: self)
        view.addItem(.separator())
        item(
            L10n.text("Toggle Full Screen"),
            #selector(NSWindow.toggleFullScreen(_:)),
            "f",
            view,
            modifiers: [.command, .control],
        )
        let windowMenu = section(L10n.text("Window"))
        item(L10n.text("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", windowMenu)
        item(L10n.text("Zoom"), #selector(NSWindow.performZoom(_:)), "", windowMenu)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printDocument) {
            return workspace.serviceReady && !workspace.exporting && !workspace.isLibraryHome
        }
        return true
    }

    @objc private func runWritingCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let command = WritingCommand.all.first(where: { $0.id == id })
        else {
            return
        }
        workspace.execute(command)
    }

    @objc private func about() {
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let commit = Bundle.main.object(forInfoDictionaryKey: "LeftBlankCommit") as? String
        let version = AppDistribution
            .current == .preview ? "\(release) (\(build))" + (commit.map { " · " + String($0.prefix(7)) } ?? "") :
            release
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppDistribution.current.applicationName,
            .applicationVersion: version,
            .credits: NSAttributedString(string: L10n.text("Ink for your thoughts")),
        ])
    }

    @objc private func settings() {
        if settingsController == nil {
            settingsController = WorkspaceSettings(workspace: workspace)
        }
        if settingsWindow == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 530, height: 690),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false,
            )
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: WritingSettingsView(
                workspace: workspace,
                library: workspace.library,
            ))
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.title = L10n.text("Settings")
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLibrary() {
        workspace.openLibrary()
    }

    @objc private func importDocument() {
        workspace.library.importPanel()
    }

    @objc private func newDocument() {
        workspace.newDocument()
    }

    @objc private func openDocument() {
        workspace.openPanel()
    }

    @objc private func recoverDraft() {
        workspace.openPanel(recovery: true)
    }

    @objc private func saveDocument() {
        workspace.save()
    }

    @objc private func documentHistory() {
        workspace.openHistory()
    }

    @objc private func saveAs() {
        workspace.saveAs()
    }

    @objc private func exportPDF() {
        workspace.exportPDF()
    }

    @objc private func printDocument() {
        workspace.printDocument()
    }

    @objc private func palette() {
        workspace.togglePalette()
    }

    @objc private func revealLogs() {
        workspace.revealLogs()
    }

    @objc private func writing() {
        workspace.layout = .writing
    }

    @objc private func split() {
        workspace.layout = .split
    }

    @objc private func preview() {
        workspace.layout = .preview
    }

    @objc private func increaseFont() {
        workspace.fontSize = min(28, workspace.fontSize + 1)
    }

    @objc private func decreaseFont() {
        workspace.fontSize = max(12, workspace.fontSize - 1)
    }

    @objc private func completion() {
        workspace.requestCompletion()
    }

    @objc private func find() {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        workspace.editor?.performFindPanelAction(sender)
    }
}

#if LEFTBLANK_PREVIEW
    import Sparkle

    /// Sparkle owns consent, scheduling, download verification and installation UI.
    /// Creating this object performs no network work; startup follows window setup.
    @MainActor
    final class PreviewUpdater: NSObject, NSMenuItemValidation {
        let controller: SPUStandardUpdaterController

        override init() {
            controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil,
            )
            super.init()
        }

        func start() {
            // A SwiftPM test executable has no app update identity or signing keys.
            guard Bundle.main.bundleIdentifier == AppDistribution.preview.bundleIdentifier else {
                return
            }
            controller.startUpdater()
        }

        func makeCheckMenuItem() -> NSMenuItem {
            let item = NSMenuItem(
                title: L10n.text("Check for Updates…"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: "",
            )
            item.target = controller
            item.identifier = NSUserInterfaceItemIdentifier("preview.checkForUpdates")
            return item
        }

        func makeAutomaticChecksMenuItem() -> NSMenuItem {
            let item = NSMenuItem(
                title: L10n.text("Automatically Check for Updates"),
                action: #selector(toggleAutomaticChecks(_:)),
                keyEquivalent: "",
            )
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("preview.automaticChecks")
            return item
        }

        @objc private func toggleAutomaticChecks(_ sender: NSMenuItem) {
            // Keep a single source of truth in Sparkle; only explicit user actions
            // write this preference. Info.plist requires confirmation to install.
            controller.updater.automaticallyChecksForUpdates.toggle()
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            guard menuItem.action == #selector(toggleAutomaticChecks(_:)) else {
                return false
            }
            menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
            return true
        }
    }
#endif
