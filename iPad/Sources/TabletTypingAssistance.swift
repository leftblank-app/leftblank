import LeftBlankCore
import UIKit

extension TabletWorkspace {
    func requestTypingAssistance(automatic: Bool) {
        guard let snapshot = assistanceSnapshot(), layout != .preview, panel == nil, canEditSource else {
            return
        }
        assistance.invalidate()
        assistance.kind = .completion
        assistance.loading = true
        let request = assistance.requestID
        assistance.task = Task { [weak self] in
            guard let self else {
                return
            }
            let context = await TypingContext.resolve(source: snapshot.source, selection: snapshot.selection)
            guard !Task.isCancelled, request == assistance.requestID, accepts(snapshot) else {
                return
            }
            guard !automatic || context != nil else {
                assistance.loading = false
                return
            }
            do {
                let params: [String: Any] = [
                    "textDocument": ["uri": snapshot.url.absoluteString],
                    "position": TextPosition(offset: snapshot.selection.location, in: snapshot.source).json,
                ]
                var items: [SourceCompletion] = []
                var signature: LanguageSignature?
                if !automatic || context?.wantsCompletion == true {
                    let result = try await client.request("textDocument/completion", params.merging([
                        "context": ["triggerKind": 1],
                    ]) { _, new in new })
                    items = LanguageAssistance.completions(
                        result,
                        source: snapshot.source,
                        selection: snapshot.selection,
                    )
                }
                if context?.wantsSignature == true, client.supports("signatureHelpProvider"), !Task.isCancelled {
                    signature = try await LanguageAssistance.signatureHelp(client.request(
                        "textDocument/signatureHelp",
                        params,
                    ))
                }
                guard !Task.isCancelled, request == assistance.requestID, accepts(snapshot), canEditSource,
                      layout != .preview
                else {
                    return
                }
                assistance.loading = false
                assistance.snapshot = snapshot
                assistance.completions = items
                assistance.signature = signature
                (editor as? TabletTextView)?.presentTypingAssistance(
                    items,
                    signature: signature,
                    prefix: context?.prefix ?? "",
                )
                if !automatic, items.isEmpty, signature == nil {
                    message = L10n.text("No completions are available here.")
                }
            } catch {
                if request == assistance.requestID {
                    assistance.loading = false
                }
                if !automatic, request == assistance.requestID, accepts(snapshot), !Task.isCancelled {
                    message = error.localizedDescription
                }
            }
        }
    }
}

extension TabletTextView {
    func scheduleTypingAssistance() {
        dismissTypingAssistance()
        guard isEditable, markedTextRange == nil, selectedRange.length == 0 else {
            return
        }
        let request = typingRequestID
        typingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, request == typingRequestID else {
                return
            }
            typingTask = nil
            if markedTextRange == nil {
                workspace?.requestTypingAssistance(automatic: true)
            }
        }
    }

    func dismissTypingAssistance() {
        typingTask?.cancel()
        typingTask = nil
        typingRequestID = UUID()
        typingList = CompletionList(items: [], prefix: "")
        typingSignature = nil
        typingOverlay?.removeFromSuperview()
        typingOverlay = nil
    }

    func presentTypingAssistance(_ items: [SourceCompletion], signature: LanguageSignature?, prefix: String) {
        guard markedTextRange == nil, isEditable else {
            return
        }
        typingList = CompletionList(items: items, prefix: prefix)
        typingSignature = signature
        renderTypingAssistance()
    }

    private func renderTypingAssistance() {
        typingOverlay?.removeFromSuperview()
        typingOverlay = nil
        guard !typingList.items.isEmpty || typingSignature != nil else {
            return
        }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.backgroundColor = .secondarySystemBackground
        stack.layer.cornerRadius = 10
        stack.layer.shadowOpacity = 0.15
        stack.layer.shadowRadius = 6
        stack.accessibilityIdentifier = "typing-assistance"
        let rows = UIStackView()
        rows.axis = .vertical
        let scroll = UIScrollView()
        scroll.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(5, typingList.items.count)) * 44),
        ])
        if !typingList.items.isEmpty {
            stack.addArrangedSubview(scroll)
        }
        for index in typingList.items.indices {
            let item = typingList.items[index]
            let button = UIButton(type: .system)
            button.setTitle((index == typingList.index ? "› " : "  ") + item.label, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(
                ofSize: 14,
                weight: index == typingList.index ? .semibold : .regular,
            )
            button.contentHorizontalAlignment = .leading
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.accessibilityIdentifier = "completion-item-\(index)"
            button.addAction(UIAction { [weak self] _ in self?.workspace?.applyCompletion(item) }, for: .touchUpInside)
            rows.addArrangedSubview(button)
        }
        if let item = typingList.selected, !item.detail.isEmpty {
            addTypingLabel(item.detail, to: stack)
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
                addTypingLabel(signature.parameterDocumentation, to: stack)
            }
        }
        typingOverlay = stack
        addSubview(stack)
        positionTypingAssistance()
        scroll.layoutIfNeeded()
        scroll.scrollRectToVisible(
            CGRect(x: 0, y: CGFloat(typingList.index) * 44, width: 1, height: 44),
            animated: false,
        )
    }

    private func addTypingLabel(_ text: String, to stack: UIStackView) {
        let label = UILabel()
        label.text = String(text.prefix(240))
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        stack.addArrangedSubview(label)
    }

    func positionTypingAssistance() {
        guard let overlay = typingOverlay else {
            return
        }
        let width = min(400, max(120, bounds.width - 24))
        let size = overlay.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        let caret = selectedTextRange.map { caretRect(for: $0.end) } ?? .zero
        let bottom = bounds.maxY - adjustedContentInset.bottom - 8
        let y = caret.maxY + size.height + 8 <= bottom ? caret.maxY + 8 : max(
            bounds.minY + 8,
            caret.minY - size.height - 8,
        )
        overlay.frame = CGRect(
            x: min(max(12, caret.minX), bounds.width - width - 12),
            y: y,
            width: width,
            height: size.height,
        )
    }

    /// Escape reaches the editor without visible suggestions. Cancel a debounce or an
    /// automatic request silently so it cannot appear after the key was handled elsewhere.
    func cancelPendingTypingAssistance() {
        guard typingOverlay == nil, markedTextRange == nil else {
            return
        }
        if let assistance = workspace?.assistance, assistance.kind == .completion, assistance.loading {
            assistance.invalidate()
        }
        if typingTask != nil {
            dismissTypingAssistance()
        }
    }

    @objc func dismissTypingFromKeyboard() {
        workspace?.assistance.invalidate()
        dismissTypingAssistance()
    }

    @objc func nextTypingCompletion() {
        typingList.move(1)
        renderTypingAssistance()
    }

    @objc func previousTypingCompletion() {
        typingList.move(-1)
        renderTypingAssistance()
    }

    @objc func acceptTypingFromKeyboard() {
        guard markedTextRange == nil, let item = typingList.selected else {
            return
        }
        workspace?.applyCompletion(item)
    }
}
