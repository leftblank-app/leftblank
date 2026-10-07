#if LEFTBLANK_PREVIEW
    import Foundation
    import LeftBlankCore
    import Sparkle
    import SwiftUI

    /// LeftBlank Preview's update channels, chosen per Mac. Nightly builds are
    /// Sparkle's default channel; alpha builds, published after every merge to
    /// main, are offered only once this Mac opts in.
    enum PreviewUpdateChannel: String, CaseIterable {
        case nightly
        case alpha

        static let defaultsKey = "PreviewUpdateChannel"

        /// The Sparkle channels allowed in addition to the default channel.
        var sparkleChannels: Set<String> {
            self == .alpha ? ["alpha"] : []
        }
    }

    /// Answers Sparkle's channel question from this Mac's stored choice.
    final class PreviewChannelDelegate: NSObject, SPUUpdaterDelegate {
        private let defaults: UserDefaults

        init(defaults: UserDefaults) {
            self.defaults = defaults
        }

        var channel: PreviewUpdateChannel {
            get {
                defaults.string(forKey: PreviewUpdateChannel.defaultsKey)
                    .flatMap(PreviewUpdateChannel.init) ?? .nightly
            }
            set { defaults.set(newValue.rawValue, forKey: PreviewUpdateChannel.defaultsKey) }
        }

        func allowedChannels(for _: SPUUpdater) -> Set<String> {
            channel.sparkleChannels
        }
    }

    /// The Updates section of Preview's General settings.
    struct PreviewUpdateSettings: View {
        @ObservedObject var updater: PreviewUpdater
        @State private var automaticUpdateChecks = false

        /// The channel picker's selection: choosing stores it and checks at once.
        static func channelSelection(_ updater: PreviewUpdater) -> Binding<PreviewUpdateChannel> {
            Binding(get: { updater.channel }, set: { updater.select($0) })
        }

        var body: some View {
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
                Picker(
                    L10n.text("Update Channel"),
                    selection: Self.channelSelection(updater),
                ) {
                    Text(L10n.text("Nightly (more stable)")).tag(PreviewUpdateChannel.nightly)
                    Text(L10n.text("Every merge (Alpha)")).tag(PreviewUpdateChannel.alpha)
                }.accessibilityIdentifier("settings.updates.channel")
                Text(L10n.text(
                    "Alpha builds arrive after every merge to main. After switching back to Nightly, the next nightly build newer than this one installs.",
                ))
                .font(.footnote).foregroundStyle(Theme.secondary)
            } header: { Text(L10n.text("Updates")) }
        }
    }
#endif
