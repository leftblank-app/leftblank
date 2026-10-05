import LeftBlankCore
import OSLog
import SwiftUI
import UIKit

@MainActor
final class TabletSourceHover: NSObject, UIGestureRecognizerDelegate {
    private weak var editor: TabletTextView?
    private var request: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var range: NSRange?
    private var viewport: CGRect?
    private let logger = Logger(subsystem: "app.leftblank.writer", category: "source-hover")
    private(set) var host: UIHostingController<TabletHoverCard>?
    private var installed = false

    init(editor: TabletTextView) {
        self.editor = editor
    }

    func install() {
        guard !installed, let editor else {
            return
        }
        installed = true
        editor.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        let click = UITapGestureRecognizer(target: self, action: #selector(commandClick(_:)))
        click.delegate = self
        editor.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deactivated),
            name: UIScene.willDeactivateNotification,
            object: nil,
        )
    }

    @objc private func deactivated() {
        dismiss()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command
    }

    @objc private func commandClick(_ gesture: UITapGestureRecognizer) {
        guard let editor, editor.markedTextRange == nil,
              let offset = offset(at: gesture.location(in: editor))
        else {
            return
        }
        dismiss()
        editor.selectedRange = NSRange(location: offset, length: 0)
        editor.workspace?.selection = editor.selectedRange
        editor.workspace?.goToDefinition()
    }

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        if gesture.state == .ended || gesture.state == .cancelled {
            scheduleDismissal()
        } else if let editor {
            move(to: gesture.location(in: editor))
        }
    }

    func offset(at point: CGPoint) -> Int? {
        guard let editor, let range = editor.characterRange(at: point),
              editor.firstRect(for: range).contains(point)
        else {
            return nil
        }
        let offset = editor.offset(from: editor.beginningOfDocument, to: range.start)
        return offset < editor.text.utf16.count ? offset : nil
    }

    func move(to point: CGPoint) {
        guard let editor, let workspace = editor.workspace, workspace.panel == nil,
              workspace.layout != .preview, editor.typingOverlay == nil,
              let offset = offset(at: point), let snapshot = workspace.assistanceSnapshot(),
              let target = LanguageAssistance.hoverRange(at: offset, in: editor.text)
        else {
            scheduleDismissal()
            return
        }
        keepVisible()
        guard range != target else {
            return
        }
        dismiss()
        range = target
        viewport = editor.bounds
        logger.notice("Hover started")
        request = Task { [weak self, weak workspace] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self, let workspace, workspace.client.supports("hoverProvider") else {
                    return
                }
                let response = try await workspace.client.request("textDocument/hover", [
                    "textDocument": ["uri": snapshot.url.absoluteString],
                    "position": TextPosition(offset: offset, in: snapshot.source).json,
                ])
                logger.notice("Hover response received")
                guard !Task.isCancelled, workspace.accepts(snapshot), workspace.panel == nil,
                      range == target, let help = LanguageAssistance.hover(response)
                else {
                    return
                }
                present(help, range: target, workspace: workspace)
            } catch { /* Passive help never interrupts editing. */ }
        }
    }

    func keepVisible() {
        dismissal?.cancel()
        dismissal = nil
    }

    func scheduleDismissal() {
        guard host != nil else {
            dismiss()
            return
        }
        guard dismissal == nil else {
            return
        }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.dismiss()
        }
    }

    func viewportChanged() {
        guard viewport != editor?.bounds else {
            return
        }
        dismiss()
    }

    func dismiss(reason: String = #function) {
        if range != nil || host != nil {
            logger.notice("Hover dismissed: \(reason, privacy: .public)")
        }
        viewport = nil
        request?.cancel()
        request = nil
        keepVisible()
        range = nil
        host?.view.removeFromSuperview()
        host = nil
    }

    private func present(_ help: LanguageHover, range: NSRange, workspace: TabletWorkspace) {
        guard let editor, let parent = editor.superview else {
            return
        }
        guard let start = editor.position(from: editor.beginningOfDocument, offset: range.location),
              let end = editor.position(from: start, offset: range.length),
              let textRange = editor.textRange(from: start, to: end)
        else {
            return
        }
        let rect = editor.firstRect(for: textRange)
        guard rect.intersects(editor.bounds) else {
            return
        }
        let anchor = editor.convert(rect, to: parent)
        let width = min(360, parent.bounds.width - 16), height = min(400, parent.bounds.height - 16)
        guard width > 0, height > 0 else {
            return
        }
        let name = (editor.text as NSString).substring(with: range)
        let card = UIHostingController(rootView: TabletHoverCard(
            name: name,
            help: help,
            workspace: workspace,
            entered: { [weak self] in self?.keepVisible() },
            exited: { [weak self] in self?.scheduleDismissal() },
            close: { [weak self] in self?.dismiss() },
        ))
        card.view.backgroundColor = .clear
        let below = anchor.maxY + 8
        card.view.frame = CGRect(
            x: min(max(8, anchor.minX), parent.bounds.maxX - width - 8),
            y: max(8, min(
                below + height <= parent.bounds.maxY ? below : anchor.minY - height - 8,
                parent.bounds.maxY - height - 8,
            )),
            width: width,
            height: height,
        )
        parent.addSubview(card.view)
        host = card
        logger.notice("Hover presented")
    }
}

struct TabletHoverCard: View {
    let name: String
    let help: LanguageHover
    let workspace: TabletWorkspace
    let entered: () -> Void
    let exited: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TabletIcon(name: "info").frame(width: 16, height: 16).foregroundStyle(TabletTheme.accent)
                Text(name).font(.system(.callout, design: .monospaced)).lineLimit(1)
                Spacer()
                Button(action: close) {
                    TabletIcon(name: "x").frame(width: 32, height: 32)
                }.accessibilityLabel(L10n.text("Close"))
            }.padding(.horizontal, 12)
            Divider()
            ScrollView { TabletHelpContent(help: help, workspace: workspace).padding(12) }
        }.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.2)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .onHover {
                hovering in if hovering {
                    entered()
                } else {
                    exited()
                }
            }
            .accessibilityIdentifier("source-hover")
    }
}
