import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import SwiftUI
import Testing
#if LEFTBLANK_PREVIEW
    import Sparkle
#endif

extension WritingFlowTests {
    @Test func distributionUsesMatchingAppIdentity() throws {
        let app = try WritingFixture(text: "A separate preview", startService: false)
        defer { app.close() }
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        let delegate = AppDelegate(workspace: app.workspace)
        delegate.installMenu()
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        #expect(appMenu.title == AppDistribution.current.applicationName)
        #expect(!appMenu.items.contains { $0.identifier?.rawValue == "preview.automaticChecks" })
        let documentMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == L10n.text("Documents") }?
            .submenu)
        #expect(!documentMenu.items.contains { $0.title == L10n.text("Recover Draft Copy…") })
        let viewMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == L10n.text("View") }?.submenu)
        #expect(!viewMenu.items.contains { $0.title == L10n.text("Open Diagnostic Logs") })
        let check = appMenu.items.first { $0.identifier?.rawValue == "preview.checkForUpdates" }
        #if LEFTBLANK_PREVIEW
            #expect(AppDistribution.current == .preview)
            #expect(!LibraryCloudEnvironment.preferenceSyncAvailable())
            #expect(throws: LibraryError.self) { try LibraryCloudEnvironment.containerURL() }
            #expect(check?.target is SPUStandardUpdaterController)
            let controller = try #require(check?.target as? SPUStandardUpdaterController)
            #expect(!controller.updater.sessionInProgress, "Menu construction must not check the network")
        #else
            #expect(AppDistribution.current == .standard)
            #expect(check == nil, "Direct and App Store builds must not expose an external updater")
        #endif
    }

    #if LEFTBLANK_PREVIEW
        @Test func sparkleAcceptsIncreasingBuildNumbersWithoutMarketingVersionBumps() {
            let comparator = SUStandardVersionComparator()
            #expect(comparator.compareVersion("9.1", toVersion: "10.1") == .orderedAscending)
            #expect(comparator.compareVersion("10.1", toVersion: "10.2") == .orderedAscending)
            #expect(comparator.compareVersion("10.2", toVersion: "10.1") == .orderedDescending)
            #expect(comparator.compareVersion("10.2", toVersion: "10.2") == .orderedSame)
            let updater = PreviewUpdater()
            let check = updater.makeCheckMenuItem()
            #expect(check.target === updater.controller)
            #expect(check.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
            updater.start()
            #expect(!updater.controller.updater.sessionInProgress)
        }

        @Test func previewOffersAlphaBuildsOnlyAfterThisMacOptsIn() throws {
            let suite = "app.leftblank.tests.update-channel.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let checks = UpdateCheckCounter()
            let updater = PreviewUpdater(defaults: defaults) { _ in checks.count += 1 }
            let sparkle = updater.controller.updater
            #expect(updater.channel == .nightly)
            #expect(updater.channels.allowedChannels(for: sparkle).isEmpty, "Nightly is Sparkle's default channel")

            updater.select(.alpha)
            #expect(updater.channels.allowedChannels(for: sparkle) == ["alpha"])
            #expect(checks.count == 1, "Switching channels checks for updates at once")
            updater.select(.alpha)
            #expect(checks.count == 1, "Selecting the current channel does not check again")
            #expect(defaults.string(forKey: PreviewUpdateChannel.defaultsKey) == "alpha")
            let relaunched = PreviewUpdater(defaults: defaults) { _ in }
            #expect(relaunched.channel == .alpha, "The choice persists on this Mac")
            #expect(relaunched.channels.allowedChannels(for: relaunched.controller.updater) == ["alpha"])

            updater.select(.nightly)
            #expect(updater.channels.allowedChannels(for: sparkle).isEmpty)
            #expect(checks.count == 2)
            defaults.set("beta", forKey: PreviewUpdateChannel.defaultsKey)
            #expect(PreviewUpdater(defaults: defaults) { _ in }.channel == .nightly, "Unknown values fall back")
            #expect(!sparkle.sessionInProgress, "Tests never reach the network")
        }

        @Test func generalSettingsShowTheUpdateChannelControl() async throws {
            let app = try WritingFixture(text: "Channels", startService: false)
            defer { app.close() }
            let suite = "app.leftblank.tests.update-channel.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let checks = UpdateCheckCounter()
            let updater = PreviewUpdater(defaults: defaults) { _ in checks.count += 1 }
            let settings = NSHostingView(rootView: WritingSettingsView(
                workspace: app.workspace,
                library: app.workspace.library,
                updater: updater,
            ))
            settings.frame = NSRect(origin: .zero, size: WritingSettingsView.windowSize)
            let window = NSWindow(contentRect: settings.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = settings
            settings.layoutSubtreeIfNeeded()
            await app.layout()
            // SwiftUI draws Form pickers itself; the Updates section's toggle is an
            // AppKit switch, so its presence shows the section rendered.
            #expect(subview(of: settings) { String(describing: type(of: $0)).contains("Switch") } != nil)

            // The picker's own selection binding, as a choice in the menu drives it.
            let selection = PreviewUpdateSettings.channelSelection(updater)
            #expect(selection.wrappedValue == .nightly)
            selection.wrappedValue = .alpha
            settings.layoutSubtreeIfNeeded()
            await app.layout()
            #expect(updater.channel == .alpha && selection.wrappedValue == .alpha)
            #expect(updater.channels.allowedChannels(for: updater.controller.updater) == ["alpha"])
            #expect(defaults.string(forKey: PreviewUpdateChannel.defaultsKey) == "alpha")
            #expect(checks.count == 1, "Switching channels checks for updates at once")
            selection.wrappedValue = .nightly
            #expect(updater.channels.allowedChannels(for: updater.controller.updater).isEmpty)
            #expect(checks.count == 2)
            #expect(PreviewUpdateChannel.allCases.map(\.rawValue) == ["nightly", "alpha"])
            #expect(L10n.text("Update Channel", language: .simplifiedChinese) == "更新通道")
            #expect(L10n.text("Nightly (more stable)", language: .simplifiedChinese) == "每晚（较稳定）")
            #expect(L10n.text("Every merge (Alpha)", language: .simplifiedChinese) == "每次合入（Alpha）")
        }
    #endif
}

#if LEFTBLANK_PREVIEW
    @MainActor
    private final class UpdateCheckCounter {
        var count = 0
    }

    @MainActor
    private func subview(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) {
            return view
        }
        for child in view.subviews {
            if let found = subview(of: child, where: matches) {
                return found
            }
        }
        return nil
    }
#endif
