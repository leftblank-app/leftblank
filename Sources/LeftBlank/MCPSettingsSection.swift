import AppKit
import LeftBlankCore
import SwiftUI

struct MCPSettingsSection: View {
    @ObservedObject var connection: MCPConnection
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            Text(L10n.text(connection.isRunning ? "Connection enabled" : "Connection disabled"))
                .accessibilityIdentifier("settings.agent.status")
            Text(L10n
                .text(
                    "Enable a local coding agent to read and edit all documents in your library while LeftBlank is running. You can disconnect at any time.",
                ))
                .font(.footnote).foregroundStyle(Theme.secondary)
            if connection.isRunning {
                Text(L10n.text(connection.grantedDocumentIDs == nil
                        ? "All documents, including new documents" : "Selected document") + " · " +
                    L10n.text(connection.allowsEditing ? "Allow Editing" : "Read Only"))
                    .font(.footnote)
                HStack {
                    Button(L10n.text("Copy Agent Setup Prompt")) { copyPrompt() }
                        .accessibilityIdentifier("settings.agent.copy")
                    Button(L10n.text("Disconnect Coding Agent")) {
                        connection.disable()
                        message = nil
                    }
                    .accessibilityIdentifier("settings.agent.disconnect")
                }
            } else {
                Button(L10n.text("Enable Connection")) { enable() }
                    .disabled(working)
                    .accessibilityIdentifier("settings.agent.enable")
                if connection.isEnabled {
                    Button(L10n.text("Disconnect Coding Agent")) {
                        connection.disable()
                        message = nil
                    }
                    .accessibilityIdentifier("settings.agent.disconnect")
                }
            }
            if working {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.secondary)
            }
            if let failure = connection.failureMessage {
                Text(failure).font(.footnote).foregroundStyle(Theme.red)
            }
        } header: { Text(L10n.text("Coding Agent")) }
            .disabled(working)
    }

    private func enable() {
        working = true
        message = nil
        Task { @MainActor in
            defer { working = false }
            do { try await connection.enable() }
            catch { message = error.localizedDescription }
        }
    }

    private func copyPrompt() {
        do {
            let prompt = try connection.setupPrompt()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            message = L10n.text("Prompt copied. Paste it into your coding agent on this Mac.")
        } catch { message = error.localizedDescription }
    }
}
