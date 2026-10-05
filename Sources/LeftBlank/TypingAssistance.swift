import AppKit
import LeftBlankCore

extension ManuscriptTextView {
    func scheduleTypingAssistance() {
        dismissTypingAssistance()
        guard isEditable, !hasMarkedText(), selectedRange().length == 0 else {
            return
        }
        let request = typingRequestID
        typingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, request == typingRequestID, !hasMarkedText() else {
                return
            }
            typingTask = nil
            workspace?.requestCompletion(automatic: true)
        }
    }

    func dismissTypingAssistance() {
        typingTask?.cancel()
        typingTask = nil
        typingRequestID = UUID()
        typingList = CompletionList(items: [], prefix: "")
        typingSignature = nil
        if let typingPanel {
            window?.removeChildWindow(typingPanel)
            typingPanel.orderOut(nil)
        }
        typingPanel = nil
    }

    func presentTypingAssistance(
        _ items: [SourceCompletion], signature: LanguageSignature?, source: String,
        selection: NSRange, requestID: UUID, prefix: String = "",
    ) {
        guard requestID == typingRequestID, string == source, selectedRange() == selection,
              !hasMarkedText(), isEditable
        else {
            return
        }
        typingSource = source
        typingSelection = selection
        typingList = CompletionList(items: items, prefix: prefix)
        typingSignature = signature
        renderTypingAssistance()
    }

    private func renderTypingAssistance() {
        guard let window else {
            return
        }
        if typingList.items.isEmpty, typingSignature == nil {
            return
        }
        let panel: NSPanel
        if let existing = typingPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.hasShadow = true
            panel.backgroundColor = .windowBackgroundColor
            panel.level = .floating
            typingPanel = panel
            window.addChildWindow(panel, ordered: .above)
        }
        let stack = NSStackView()
        stack.setAccessibilityIdentifier("typing-assistance")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let start = max(0, typingList.index - 5)
        for index in start ..< min(start + 8, typingList.items.count) {
            let item = typingList.items[index]
            let button = NSButton(
                title: (index == typingList.index ? "› " : "  ") + item.label,
                target: self,
                action: #selector(chooseTypingCompletion(_:)),
            )
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: 12, weight: index == typingList.index ? .semibold : .regular)
            button.setAccessibilityIdentifier("completion-item-\(index)")
            button.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stack.addArrangedSubview(button)
        }
        if let selected = typingList.selected, !selected.detail.isEmpty {
            addTypingLabel(String(selected.detail.prefix(240)), to: stack)
        }
        if let signature = typingSignature {
            addTypingLabel(signature.label, to: stack)
            if let parameter = signature.activeParameter {
                addTypingLabel(
                    L10n.format("Parameter: %@", parameter),
                    to: stack,
                )
            }
            if !signature.parameterDocumentation.isEmpty {
                addTypingLabel(String(signature.parameterDocumentation.prefix(240)), to: stack)
            }
        }
        panel.contentView = stack
        let size = stack.fittingSize
        let caret = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? window.frame
        let x = min(max(caret.minX, screen.minX), screen.maxX - size.width)
        let y = caret.minY - size.height >= screen.minY ? caret.minY - size.height : caret.maxY
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFront(nil)
    }

    private func addTypingLabel(_ text: String, to stack: NSStackView) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.widthAnchor.constraint(equalToConstant: 360).isActive = true
        stack.addArrangedSubview(label)
    }

    func handleTypingKey(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(),
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else {
            return false
        }
        if event.keyCode == 53, typingPanel != nil || typingTask != nil {
            dismissTypingAssistance()
            return true
        }
        guard typingList.selected != nil else {
            return false
        }
        switch event.keyCode {
        case 125: typingList.move(1)
            renderTypingAssistance()
            return true
        case 126: typingList.move(-1)
            renderTypingAssistance()
            return true
        case 48 where !event.modifierFlags.contains(.shift):
            if let selected = typingList.selected {
                acceptTypingCompletion(selected)
            }
            return true
        default: return false
        }
    }

    @objc private func chooseTypingCompletion(_ sender: NSButton) {
        guard typingList.items.indices.contains(sender.tag) else {
            return
        }
        acceptTypingCompletion(typingList.items[sender.tag])
    }

    func acceptTypingCompletion(_ item: SourceCompletion) {
        guard typingList.items.contains(item), string == typingSource, selectedRange() == typingSelection,
              !hasMarkedText(), isEditable, let workspace, workspace.text == string
        else {
            return
        }
        do {
            let updated = try TextEditing.applying(item.edits, to: string)
            let start = item.edits.map(\.range.location).min() ?? 0
            let end = item.edits.map { NSMaxRange($0.range) }.max() ?? start
            let length = end - start + updated.utf16.count - string.utf16.count
            let replacement = (updated as NSString).substring(with: NSRange(location: start, length: length))
            dismissTypingAssistance()
            insertSnippet(Snippet(text: replacement), replacing: NSRange(location: start, length: end - start))
            setCompletionPlaceholders(item.selections)
            setSelectedRange(item.selections.first ?? NSRange(location: item.insertionEnd, length: 0))
            workspace.selection = selectedRange()
            scheduleTypingAssistance()
        } catch { workspace.showMessage(error.localizedDescription) }
    }
}
