import Foundation
import LeftBlankCore
import UIKit

@MainActor
final class TabletLibraryObserver {
    private weak var workspace: TabletWorkspace?
    private var monitor: LibraryFileMonitor?
    private var cloudQuery: LibraryCloudQuery?
    private var accountMonitor: LibraryAccountMonitor?
    private var refreshTask: Task<Void, Never>?

    init(workspace: TabletWorkspace) {
        self.workspace = workspace
    }

    func start() async {
        guard let workspace else {
            return
        }
        monitor?.stop()
        cloudQuery = nil
        let root = await workspace.library.rootURL
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        monitor = LibraryFileMonitor(rootURL: root, onChange: changed)
        if workspace.cloudEnabled {
            cloudQuery = LibraryCloudQuery(rootURL: root, onChange: changed)
        }
        accountMonitor = LibraryAccountMonitor { [weak workspace] in
            Task { @MainActor [weak workspace] in
                guard let workspace, workspace.cloudEnabled else {
                    return
                }
                workspace.persistRecovery()
                workspace.message = L10n
                    .text(
                        "The iCloud account changed. Your writing is preserved. Check iCloud settings before continuing sync.",
                    )
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.workspace?.refreshFromLibrary()
        }
    }

    deinit {
        refreshTask?.cancel()
        monitor?.stop()
    }
}

extension TabletWorkspace {
    /// A second window or iCloud may save while this editor remains open.
    /// Adopt clean edits and merge independent lines; preserve overlapping edits.
    func refreshFromLibrary() async {
        do { try await reloadLibrary() } catch {
            message = error.localizedDescription
            return
        }
        guard !busy, !changing, let url = sourceURL, editor?.markedTextRange == nil else {
            return
        }
        let base = savedText, original = text, caret = selection, revision = version, session = generation
        let disk = await Task.detached(priority: .utility) { try? DocumentStorage.read(url) }.value
        guard let (remote, diskBaseline) = disk, remote != base else {
            return
        }
        let merged = await Task.detached(priority: .utility) {
            DocumentMerge.merge(base: base, local: original, remote: remote, selection: caret)
        }.value
        guard !busy, !changing, sourceURL == url, generation == session, version == revision,
              savedText == base, selection == caret, editor?.markedTextRange == nil
        else {
            return
        }
        guard let merged else {
            persistRecovery()
            saveStatus = "Save Needs Attention"
            message = L10n
                .text(
                    "This paragraph changed on another device. Your writing is safe; resolve the conflict before saving.",
                )
            return
        }
        // An expired subscription can still receive a clean remote revision.
        // A dirty buffer stays intact until editing is available again.
        guard canWrite || original == base || merged.text == original else {
            return
        }
        baseline = diskBaseline
        savedText = remote
        if merged.text != text {
            if canWrite, let editor {
                let origin = editor.contentOffset
                apply(
                    TextReplacement(range: NSRange(location: 0, length: text.utf16.count), text: merged.text),
                    restoringSelection: merged.selection,
                )
                editor.setContentOffset(origin, animated: false)
                editor.undoManager?.setActionName(L10n.text("Sync update"))
            } else {
                text = merged.text
                selection = merged.selection
                version += 1
                if serviceReady {
                    do { try client.change(url, text: text, version: version) }
                    catch { message = error.localizedDescription }
                }
                await refresh()
            }
        }
        saveStatus = text == savedText ? "Saved" : "Saving"
        persistRecovery()
    }

    func exportSource() {
        commitComposition()
        guard let sourceURL, !busy else {
            return
        }
        let directory = stateDirectory.appendingPathComponent("Exports")
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            try Data(text.utf8).write(to: destination, options: .atomic)
            shareURL = destination
        } catch { message = error.localizedDescription }
    }

    func printDocument() async {
        commitComposition()
        guard !busy, serviceReady, let window = editor?.window else {
            return
        }
        busy = true
        defer { busy = false }
        do {
            let url = try await compiledPDF()
            guard UIPrintInteractionController.canPrint(url) else {
                throw ServiceError.remote(L10n.text("The document could not be prepared for printing."))
            }
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = document?.title ?? L10n.text("Untitled")
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = url
            controller.present(
                from: CGRect(x: window.bounds.midX, y: 50, width: 1, height: 1),
                in: window,
                animated: true,
            ) { [weak self] _, _, error in
                if let error {
                    self?.message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }
}
