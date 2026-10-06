import AppKit
@testable import LeftBlankApp
import LeftBlankCore
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
    #endif
}
