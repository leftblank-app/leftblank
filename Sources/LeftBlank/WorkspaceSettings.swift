import AppKit
import Combine
import LeftBlankCore
import SwiftUI

@MainActor
final class WorkspaceSettings: ObservableObject {
    let preferences: LibraryPreferences
    private weak var workspace: Workspace?
    private var subscriptions: Set<AnyCancellable> = []
    private var applying = false

    init(workspace: Workspace, defaults: UserDefaults = .standard) {
        self.workspace = workspace
        preferences = LibraryPreferences(defaults: defaults)
        apply(preferences.values)
        Theme.apply(workspace.appearance)
        preferences.onChange = { [weak self] in self?.apply($0) }
        workspace.library.onSyncChange = { [weak self] in self?.preferences.setSyncEnabled($0) }
        Publishers.CombineLatest4(
            workspace.$fontSize,
            workspace.$previewDark,
            workspace.$styledSource,
            workspace.$commandKey,
        )
        .dropFirst().sink { [weak self] _, _, _, _ in
            // @Published sends before storage changes; collect after this turn.
            Task { @MainActor [weak self] in self?.persist() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .leftblankLanguageChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.persist() }
        }.store(in: &subscriptions)
        workspace.$appearance.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.persist() }
        }.store(in: &subscriptions)
        workspace.$historyInterval.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.persist() }
        }.store(in: &subscriptions)
        workspace.$documentTemplate.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.persist() }
        }.store(in: &subscriptions)
    }

    private func apply(_ value: SyncedPreferences) {
        guard let workspace else {
            return
        }
        applying = true
        defer { applying = false }
        if workspace.fontSize != value.fontSize {
            workspace.fontSize = value.fontSize
        }
        if workspace.previewDark != value.previewDark {
            workspace.previewDark = value.previewDark
        }
        if workspace.styledSource != value.styledSource {
            workspace.styledSource = value.styledSource
        }
        if workspace.commandKey != value.commandKey {
            workspace.commandKey = value.commandKey
        }
        let appearance = AppAppearance(rawValue: value.appearance ?? "system") ?? .system
        if workspace.appearance != appearance {
            workspace.appearance = appearance
        }
        let historyInterval = HistoryInterval(rawValue: value.historyInterval ?? "hourly") ?? .hourly
        if workspace.historyInterval != historyInterval {
            workspace.historyInterval = historyInterval
        }
        let template = DocumentTemplate(rawValue: value.documentTemplate ?? "blank") ?? .blank
        if workspace.documentTemplate != template {
            workspace.documentTemplate = template
        }
        if let language = AppLanguage(rawValue: value.language),
           L10n.language != language
        {
            L10n.setLanguage(language)
        }
    }

    private func persist() {
        guard !applying, let workspace else {
            return
        }
        let next = SyncedPreferences(
            language: L10n.language.rawValue,
            commandKey: workspace.commandKey,
            fontSize: workspace.fontSize,
            previewDark: workspace.previewDark,
            styledSource: workspace.styledSource,
            documentTemplate: workspace.documentTemplate.rawValue,
            historyInterval: workspace.historyInterval.rawValue,
            appearance: workspace.appearance.rawValue,
        )
        if next != preferences.values {
            preferences.update(next)
        }
    }

    func stop() {
        subscriptions.removeAll()
    }
}

struct WritingSettingsView: View {
    static let windowSize = NSSize(width: 560, height: 500)
    @ObservedObject var workspace: Workspace
    @ObservedObject var library: LibraryController
    #if LEFTBLANK_PREVIEW
        var updater: PreviewUpdater? = nil
        @State private var automaticUpdateChecks = false
    #endif
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        TabView {
            generalSettings.tabItem { Text(L10n.text("General")) }
            writingSettings.tabItem { Text(L10n.text("Writing")) }
            librarySettings.tabItem { Text(L10n.text("Library")) }
            Form {
                MCPSettingsSection(connection: workspace.agentConnection)
            }.formStyle(.grouped)
                .tabItem { Text(L10n.text("Coding Agent")) }
        }
        .padding(.top, 12)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .environment(\.locale, L10n.locale)
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker(
                    L10n.text("App Language"),
                    selection: Binding(get: { localization.language }, set: { localization.select($0) }),
                ) {
                    Text(L10n.text("Follow System")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                }.accessibilityIdentifier("settings.language")
                Picker(L10n.text("Appearance"), selection: $workspace.appearance) {
                    Text(L10n.text("Follow System")).tag(AppAppearance.system)
                    Text(L10n.text("Light")).tag(AppAppearance.light)
                    Text(L10n.text("Dark")).tag(AppAppearance.dark)
                }.accessibilityIdentifier("settings.appearance")
                Picker(L10n.text("Discover commands"), selection: $workspace.commandKey) {
                    Text("⌘J").tag("j")
                    Text("⌘K").tag("k")
                }
            }
            #if LEFTBLANK_PREVIEW
                if let updater {
                    Section {
                        Toggle(
                            L10n.text("Automatically Check for Updates"),
                            isOn: Binding(
                                get: { automaticUpdateChecks },
                                set: { updater.controller.updater.automaticallyChecksForUpdates = $0 },
                            ),
                        ).accessibilityIdentifier("settings.updates.automatic")
                            .onReceive(updater.controller.updater.publisher(for: \.automaticallyChecksForUpdates)) {
                                automaticUpdateChecks = $0
                            }
                    } header: { Text(L10n.text("Updates")) }
                }
            #endif
            Section {
                Button(L10n.text("Open Diagnostic Logs")) { workspace.revealLogs() }
            } header: { Text(L10n.text("Support")) }
        }.formStyle(.grouped)
    }

    private var writingSettings: some View {
        Form {
            Section {
                Stepper(
                    L10n.format("Editor text size: %d", Int(workspace.fontSize)),
                    value: $workspace.fontSize,
                    in: 12 ... 28,
                )
                Toggle(L10n.text("Style headings and emphasis in the editor"), isOn: $workspace.styledSource)
            } header: { Text(L10n.text("Editor")) }
            Section {
                Toggle(L10n.text("Dark preview"), isOn: $workspace.previewDark)
            } header: { Text(L10n.text("Preview")) }
        }.formStyle(.grouped)
    }

    private var librarySettings: some View {
        Form {
            Section {
                Toggle(L10n.text("Sync with iCloud"), isOn: Binding(get: { library.cloudEnabled }, set: { enabled in
                    library.perform { try await library.setCloudEnabled(enabled) }
                })).disabled(library.busy)
                Text(L10n
                    .text(
                        "Keep your library and writing preferences together across your Macs. Local originals are preserved when you turn sync on.",
                    ))
                    .font(.footnote).foregroundStyle(Theme.secondary)
                if library.busy {
                    ProgressView().controlSize(.small)
                }
                if !library.syncMessage.isEmpty {
                    Text(library.syncMessage).font(.footnote).foregroundStyle(Theme.secondary)
                }
                if let error = library.error {
                    Text(error).font(.footnote).foregroundStyle(Theme.red)
                }
            } header: { Text("iCloud") }
            Section {
                Picker(L10n.text("Keep edited versions"), selection: $workspace.historyInterval) {
                    Text(L10n.text("Every hour")).tag(HistoryInterval.hourly)
                    Text(L10n.text("Every day")).tag(HistoryInterval.daily)
                }
                Text(L10n
                    .text(
                        "Keep the latest 7 source snapshots on this Mac. No snapshots are created while a document is unchanged.",
                    ))
                    .font(.footnote).foregroundStyle(Theme.secondary)
            } header: { Text(L10n.text("Document History")) }
        }.formStyle(.grouped)
    }
}
