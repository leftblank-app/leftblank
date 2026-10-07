import AppKit
import LeftBlankCore
import SwiftUI

/// Passive source help has its own lifetime and never changes the writing selection.
@MainActor
final class SourceHoverController: NSObject {
    private weak var editor: ManuscriptTextView?
    private var request: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    /// The word under the pointer, pending or shown, and the word whose card is shown.
    private var range: NSRange?
    private var shown: NSRange?
    private let renderer = HoverExampleRenderer()
    private var previewTask: Task<Void, Never>?
    private(set) var examplePreview: HoverExamplePreview?
    private(set) var panel: NSPanel?
    private(set) var help: LanguageHover?
    /// Tests copy into a private pasteboard instead of the user's clipboard.
    var pasteboard = NSPasteboard.general
    private var pointerInCard = false

    init(editor: ManuscriptTextView) {
        self.editor = editor
    }

    func observeWindow() {
        dismiss()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window = editor?.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification,
                object: window,
            )
        }
    }

    @objc private func windowResigned(_ notification: Notification) {
        dismiss()
    }

    func move(to offset: Int?) {
        guard let editor, let workspace = editor.workspace,
              let offset, let target = LanguageAssistance.hoverRange(at: offset, in: editor.string)
        else {
            scheduleDismissal()
            return
        }
        if target == shown {
            abandonPending()
            keepVisible()
            return
        }
        guard range != target else {
            return
        }
        if panel == nil {
            dismiss()
        } else {
            // Reaching a card below crosses the next line's words. Keep it for the
            // grace period; replace it only if the pointer dwells on another word.
            request?.cancel()
            scheduleCardDismissal()
        }
        range = target
        workspace.recordOperation("hover.started", ["range": NSStringFromRange(target)])
        request = Task { [weak self, weak workspace] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, let workspace,
                  let help = await workspace.hoverHelp(at: offset), !Task.isCancelled,
                  range == target, !pointerInCard
            else {
                return
            }
            workspace.recordOperation("hover.received")
            removeCard()
            present(help, at: target)
        }
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

    func keepVisible() {
        dismissal?.cancel()
        dismissal = nil
    }

    /// The pointer left source help: abandon pending help, then hide the card after a grace period.
    func scheduleDismissal() {
        abandonPending()
        scheduleCardDismissal()
    }

    private func scheduleCardDismissal() {
        guard panel != nil else {
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

    func copyExample() {
        help?.example?.copy(to: pasteboard)
    }

    func dismiss(reason: String = #function) {
        if range != nil || panel != nil {
            editor?.workspace?.recordOperation("hover.dismissed", ["reason": reason])
        }
        request?.cancel()
        request = nil
        keepVisible()
        range = nil
        removeCard()
    }

    private func removeCard() {
        previewTask?.cancel()
        previewTask = nil
        examplePreview = nil
        help = nil
        shown = nil
        pointerInCard = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    private func present(_ help: LanguageHover, at range: NSRange) {
        guard let editor, let window = editor.window, let screen = window.screen,
              NSMaxRange(range) <= editor.string.utf16.count
        else {
            return
        }
        let anchor = editor.firstRect(forCharacterRange: range, actualRange: nil)
        let visible = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
        editor.workspace?.recordOperation("hover.anchor", [
            "anchor": NSStringFromRect(anchor), "visible": NSStringFromRect(visible),
        ])
        guard anchor.intersects(visible) else {
            return
        }
        let name = (editor.string as NSString).substring(with: range)
        let preview = HoverExamplePreview()
        let host = SourceHoverHost(rootView: SourceHoverCard(
            name: name,
            help: help,
            preview: preview,
            copyExample: { [weak self] in self?.copyExample() },
        ))
        host.entered = { [weak self] in self?.enteredCard() }
        host.exited = { [weak self] in self?.exitedCard() }
        let size = host.fittingSize
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(anchor.minX, bounds.minX), bounds.maxX - size.width)
        let below = anchor.minY - size.height - 8
        let y = max(bounds.minY, min(below >= bounds.minY ? below : anchor.maxY + 8, bounds.maxY - size.height))
        let panel = SourceHoverPanel(
            contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.appearance = editor.effectiveAppearance
        panel.contentView = host
        editor.workspace?.recordOperation("hover.presented")
        self.panel = panel
        self.help = help
        shown = range
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if let example = help.example, let workspace = editor.workspace {
            examplePreview = preview
            previewTask = Task { [weak self] in
                guard let self else {
                    return
                }
                let image = await renderer.image(
                    for: example,
                    directory: workspace.stateDirectory.appendingPathComponent("HoverExamples"),
                    packageCache: workspace.packageCache,
                )
                guard !Task.isCancelled, examplePreview === preview else {
                    return
                }
                preview.image = image
                preview.loading = false
            }
        }
    }
}

private final class SourceHoverPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private final class SourceHoverHost: NSHostingView<SourceHoverCard> {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        entered?()
    }

    override func mouseExited(with event: NSEvent) {
        exited?()
    }
}

private struct SourceHoverCard: View {
    let name: String
    let help: LanguageHover
    @ObservedObject var preview: HoverExamplePreview
    let copyExample: () -> Void
    @State private var showExample = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PhosphorIcon(name: "info", size: 14).foregroundStyle(Theme.accent)
                Text(name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer()
                if help.example != nil {
                    Button(L10n.text("Explanation")) { showExample = false }
                        .foregroundStyle(showExample ? Theme.secondary : Theme.accent)
                    Button(L10n.text("Example")) { showExample = true }
                        .foregroundStyle(showExample ? Theme.accent : Theme.secondary)
                } else {
                    Text("Typst").foregroundStyle(Theme.muted)
                }
            }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 11)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showExample, let example = help.example {
                        exampleView(example)
                    } else {
                        if let signature = help.signature, !signature.isEmpty {
                            Text(signature).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).background(
                                    Color(nsColor: Theme.codeBackground),
                                    in: RoundedRectangle(cornerRadius: 6),
                                )
                        }
                        if !help.documentation.isEmpty {
                            Text(help.documentation).font(.system(size: 12)).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true).frame(
                                    maxWidth: .infinity,
                                    alignment: .leading,
                                )
                        }
                        if let url = help.documentationURL {
                            Link(destination: url) {
                                HStack(spacing: 5) {
                                    Text(L10n.text("View Typst documentation"))
                                    PhosphorIcon(name: "arrow-square-out", size: 12)
                                }.font(.system(size: 11)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }.padding(14)
            }.frame(height: contentHeight)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                Text(L10n.text("⌘-click source to go to definition"))
                Spacer()
                Text("Esc")
            }.font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.horizontal, 14).padding(.vertical, 9)
        }.frame(width: 360).foregroundStyle(Theme.text)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.format("Help for %@", name))
    }

    private var contentHeight: CGFloat {
        if help.example != nil {
            return 300
        }
        let texts = [help.signature, help.documentation].compactMap(\.self).filter { !$0.isEmpty }
        let lines = texts.reduce(0) { total, text in
            total + text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 45))) }
        }
        return min(
            280,
            max(54, CGFloat(lines) * 18 + (help.signature == nil ? 28 : 60) + (help.documentationURL == nil ? 0 : 28)),
        )
    }

    private func exampleView(_ example: HoverExample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(example.displaySource).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10).padding(.trailing, 22)
            }.frame(height: min(
                100,
                max(38, CGFloat(example.displaySource.components(separatedBy: "\n").count) * 16 + 20),
            ))
            .background(Color(nsColor: Theme.codeBackground), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button {
                    copyExample()
                    copied = true
                } label: {
                    PhosphorIcon(name: copied ? "check" : "copy", size: 13)
                        .foregroundStyle(copied ? Theme.accent : Theme.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(4).help(L10n.text("Copy")).accessibilityLabel(L10n.text("Copy"))
            }
            .task(id: copied) {
                guard copied else {
                    return
                }
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                copied = false
            }
            if let image = preview.image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 160)
                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(L10n.text("Rendered example"))
            } else if preview.loading {
                HStack { ProgressView().controlSize(.small)
                    Text(L10n.text("Rendering example…"))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text(L10n.text("This example cannot be previewed on its own. See its documentation."))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            if let url = help.documentationURL {
                Link(L10n.text("View Typst documentation"), destination: url)
                    .font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
        }
    }
}

extension HoverExample {
    /// Copy the snippet the card shows; hidden `>>>` setup lines stay out of the user's source.
    func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(displaySource, forType: .string)
    }
}
