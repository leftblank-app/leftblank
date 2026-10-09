import LeftBlankCore
import OSLog
import SwiftUI
import UIKit

@MainActor
final class TabletSourceHover: NSObject, UIGestureRecognizerDelegate {
    private weak var editor: TabletTextView?
    private var request: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    /// The word under the pointer, pending or shown, and the word whose card is shown.
    private var range: NSRange?
    private var shown: NSRange?
    private var viewport: CGRect?
    private let logger = Logger(subsystem: "app.leftblank.writer", category: "source-hover")
    private(set) var host: UIHostingController<TabletHoverCard>?
    /// No help is pending or shown; only new pointer movement asks for more.
    var isIdle: Bool {
        range == nil
    }

    private var pointerInCard = false
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
        if target == shown, viewport == editor.bounds {
            abandonPending()
            keepVisible()
            return
        }
        guard range != target || viewport != editor.bounds else {
            return
        }
        if host == nil || viewport != editor.bounds {
            dismiss()
        } else {
            // Reaching a card below crosses the next line's words. Keep it for the
            // grace period; replace it only if the pointer dwells on another word.
            request?.cancel()
            scheduleCardDismissal()
        }
        range = target
        viewport = editor.bounds
        logger.notice("Hover started")
        request = Task { [weak self, weak workspace] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let self, let workspace, workspace.client.supports("hoverProvider") else {
                    return
                }
                let help = try await workspace.client.hoverHelp([
                    "textDocument": ["uri": snapshot.url.absoluteString],
                    "position": TextPosition(offset: offset, in: snapshot.source).json,
                ], packageCache: workspace.packageCache)
                logger.notice("Hover response received")
                guard !Task.isCancelled, workspace.accepts(snapshot), workspace.panel == nil,
                      range == target, !pointerInCard, let help
                else {
                    return
                }
                removeCard()
                present(help, range: target, workspace: workspace)
            } catch { /* Passive help never interrupts editing. */ }
        }
    }

    func keepVisible() {
        dismissal?.cancel()
        dismissal = nil
    }

    func enteredCard() {
        pointerInCard = true
        abandonPending()
        keepVisible()
    }

    func exitedCard() {
        pointerInCard = false
        scheduleDismissal()
    }

    /// The pointer left a word whose help has not arrived; only a shown card remains.
    private func abandonPending() {
        guard range != shown else {
            return
        }
        request?.cancel()
        request = nil
        range = shown
    }

    /// The pointer left source help: abandon pending help, then hide the card after a grace period.
    func scheduleDismissal() {
        abandonPending()
        scheduleCardDismissal()
    }

    private func scheduleCardDismissal() {
        guard host != nil else {
            dismiss()
            return
        }
        guard dismissal == nil else {
            return
        }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else {
                return
            }
            dismissal = nil
            guard !pointerInCard else {
                return
            }
            // A word the pointer still dwells on keeps its pending replacement.
            if range == shown {
                dismiss()
            } else {
                removeCard()
            }
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
        removeCard()
    }

    private func removeCard() {
        shown = nil
        pointerInCard = false
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
        guard let frame = Self.cardFrame(beside: editor.convert(rect, to: parent), in: parent.bounds) else {
            return
        }
        let name = (editor.text as NSString).substring(with: range)
        let card = UIHostingController(rootView: TabletHoverCard(
            name: name,
            help: help,
            workspace: workspace,
            entered: { [weak self] in self?.enteredCard() },
            exited: { [weak self] in self?.exitedCard() },
            close: { [weak self] in self?.dismiss() },
        ))
        card.view.backgroundColor = .clear
        card.view.frame = frame
        parent.addSubview(card.view)
        host = card
        shown = range
        logger.notice("Hover presented")
    }

    /// Beside the word, never over it: below if the card fits, else above,
    /// else shortened on the roomier side (landscape with the keyboard up).
    static func cardFrame(beside anchor: CGRect, in bounds: CGRect) -> CGRect? {
        let below = anchor.maxY + 8
        let room = (below: bounds.maxY - 8 - below, above: anchor.minY - 8 - bounds.minY - 8)
        let width = min(360, bounds.width - 16), height = min(400, max(room.below, room.above))
        guard width > 0, height > 0 else {
            return nil
        }
        return CGRect(
            x: min(max(bounds.minX + 8, anchor.minX), bounds.maxX - width - 8),
            y: room.below >= height ? below : anchor.minY - height - 8,
            width: width,
            height: height,
        )
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
