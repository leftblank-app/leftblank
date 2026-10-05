import AppKit
import LeftBlankCore
import SwiftUI

struct WritingAssistance {
    enum Kind: String { case help, actions }
    let kind: Kind
    let source: String
    let documentURL: URL
    let revision: Int
    let hover: LanguageHover?
    let signature: LanguageSignature?
    let actions: [SourceCodeAction]
}

struct WritingAssistanceCard: View {
    let context: WritingAssistance
    let apply: (SourceCodeAction) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PhosphorIcon(name: context.kind == .help ? "question" : "lightbulb", size: 15)
                    .foregroundStyle(Theme.accent)
                Text(L10n.text(context.kind == .help ? "Explain at Cursor" : "Actions at Cursor")).font(.system(
                    size: 12,
                    weight: .medium,
                ))
                Spacer()
                Text(context.kind == .help ? "⌃⌥H" : "⌘.").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            if context.kind == .help {
                if context.hover == nil, context.signature == nil {
                    Text(L10n.text("No explanation here yet. Try a function, variable or parameter."))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(
                            horizontal: false,
                            vertical: true,
                        )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let signature = context.signature {
                                Text(signature.label).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.accent)
                                if let parameter = signature.activeParameter {
                                    Text(L10n.format("Parameter: %@", parameter)).font(.system(
                                        size: 11,
                                        weight: .medium,
                                    ))
                                }
                                if !signature.parameterDocumentation.isEmpty {
                                    prose(signature.parameterDocumentation)
                                }
                                if !signature.documentation.isEmpty {
                                    prose(signature.documentation)
                                }
                            }
                            if let hover = context.hover {
                                prose(hover.text)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: helpHeight)
                }
            } else if context.actions.isEmpty {
                Text(L10n.text("No changes available here. Try a heading or an equation."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(
                        horizontal: false,
                        vertical: true,
                    )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(context.actions.enumerated()), id: \.offset) { _, action in
                            Button { apply(action) } label: {
                                HStack(spacing: 10) {
                                    PhosphorIcon(name: "arrow-right", size: 13).foregroundStyle(Theme.muted)
                                    Text(L10n.text(action.title)).font(.system(size: 12))
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 8).padding(.horizontal, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(280, CGFloat(context.actions.count) * 40))
            }
        }.padding(16).frame(width: 396).fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(Theme.text).background(Theme.panel)
    }

    private var helpHeight: CGFloat {
        let texts = [context.hover?.text, context.signature?.label, context.signature?.documentation,
                     context.signature?.activeParameter, context.signature?.parameterDocumentation].compactMap(\.self)
            .filter { !$0.isEmpty }
        let lines = texts.reduce(0) { total, text in
            total + text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 48))) }
        }
        return min(250, max(48, CGFloat(lines) * 19 + CGFloat(texts.count - 1) * 12))
    }

    private func prose(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}

extension ManuscriptTextView {
    func presentAssistance(_ context: WritingAssistance) {
        dismissAssistance()
        guard let window else {
            return
        }
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        let controller = NSHostingController(rootView: WritingAssistanceCard(context: context) { [weak self] in
            self?.workspace?.applyContextAction($0)
        })
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let local = convert(window.convertFromScreen(rect), from: nil)
        assistancePopover = popover
        popover.show(relativeTo: local.intersection(visibleRect), of: self, preferredEdge: .maxY)
    }

    func dismissAssistance() {
        sourceHover.dismiss()
        assistancePopover?.close()
        assistancePopover = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        for (id, selector) in [
            ("quickHelp", #selector(explainAtCursor)),
            ("contextActions", #selector(actionsAtCursor)),
            ("definition", #selector(definitionAtCursor)),
            ("navigateBack", #selector(backFromDefinition)),
        ] {
            guard let command = WritingCommand.all.first(where: { $0.id == id }) else {
                continue
            }
            let item = NSMenuItem(title: command.title, action: selector, keyEquivalent: "")
            item.target = self
            item.image = IconStore.image(command.icon)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func explainAtCursor() {
        workspace?.requestAssistance(.help)
    }

    @objc private func actionsAtCursor() {
        workspace?.requestAssistance(.actions)
    }

    @objc private func definitionAtCursor() {
        workspace?.goToDefinition()
    }

    @objc private func backFromDefinition() {
        workspace?.navigateBack()
    }
}
