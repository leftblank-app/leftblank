import Nimble
import StoreKitTest
import XCTest

/// Polls five times per second. XCTest's predicate expectations, including
/// waitForExistence, sample about once per second and first wait a full
/// interval, even when the state is already reached. File-scope helpers keep
/// Nimble's autoclosures free of implicit self captures.
@MainActor private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return true
}

@MainActor private func appears(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    poll(timeout: timeout) { element.exists }
}

@MainActor
final class WritingTests: XCTestCase {
    private var storeSession: SKTestSession?
    private static var capturedRotationFailure = false

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let session = try SKTestSession(configurationFileNamed: "LeftBlank")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        if !name.contains("testSubscriptionPurchaseAndRestore") {
            _ = try await session.buyProduct(identifier: "app.leftblank.writer.ipad.monthly")
        }
        storeSession = session
    }

    override func tearDown() async throws {
        await MainActor.run {
            XCUIApplication().terminate()
            storeSession?.clearTransactions()
            storeSession = nil
        }
        try await super.tearDown()
    }

    /// Opens a fresh built-in document. Only gallery scenarios pay for New
    /// Document, catalog loading and template selection; the rest launch with it.
    private func startWriting(
        template: String = "blank",
        language: String = "en",
        gallery: Bool = false,
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", language,
                               "-iPadCloudEnabled", "NO"]
        if !gallery {
            app.launchArguments += ["-iPadOpenTemplate", template]
        }
        launchInLandscape(app)
        if gallery {
            let create = app.buttons["new-document"].firstMatch
            let actions = app.buttons["document-actions"].firstMatch
            if actions.exists, actions.isHittable {
                // Fresh libraries open Welcome. Use its menu without waiting for
                // NavigationSplitView to reveal the sidebar after startup.
                actions.tap()
                let command = app.buttons[language == "zh-Hans" ? "新建文稿" : "New Document"]
                expect(appears(command, timeout: 60)) == true
                command.tap()
            } else {
                let enabled = NSPredicate { _, _ in (try? create.snapshot())?.isEnabled == true && create.isHittable }
                waitForState(enabled, in: app, timeout: 60)
                create.tap()
            }
            let starter = app.buttons["universe.builtin." + template]
            selectTemplate(starter, in: app)
            // An old manuscript remains in the hierarchy behind the gallery.
            // Require the creation flow to close it before accepting the editor.
            waitForState(NSPredicate { _, _ in !starter.exists }, in: app, name: "Template creation")
        }
        expect(appears(app.textViews["manuscript"].firstMatch, timeout: 60)) == true
        let settled = NSPredicate { _, _ in !app.progressIndicators["document-loading"].firstMatch.exists }
        waitForState(settled, in: app, timeout: 60)
        let duplicateSidebarCount = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Show Sidebar", "Hide Sidebar"],
        )).count
        if duplicateSidebarCount != 0 {
            capture("Duplicate sidebar controls")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Duplicate sidebar hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        expect(duplicateSidebarCount) == 0
        return app
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launchInLandscape(_ app: XCUIApplication) {
        app.launch()
        // A cold accessibility session can become ready after app.launch returns.
        // Establish the window before measuring either rotation.
        expect(appears(app.windows.firstMatch, timeout: 60)) == true
        // Scene restoration opens the engine and restores the caret asynchronously.
        // Finish that transition before rotating the editor and software keyboard.
        let loading = app.progressIndicators["document-loading"].firstMatch
        let create = app.buttons["new-document"].firstMatch
        let actions = app.buttons["document-actions"].firstMatch
        let launched = NSPredicate { _, _ in
            // One snapshot reads existence and enabled state together.
            !loading.exists && (((try? create.snapshot())?.isEnabled == true && create.isHittable) ||
                (actions.exists && actions.isHittable))
        }
        waitForState(launched, in: app, timeout: 60)
        // Most launches already inherit landscape. Rotate only when needed;
        // the dedicated rotation scenarios still exercise both orientations.
        let frame = app.windows.firstMatch.frame
        if frame.width <= frame.height {
            // Toggle the device even if it already reports landscape while the
            // restored window remains portrait.
            XCUIDevice.shared.orientation = .portrait
            waitForOrientation(in: app, landscape: false)
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        waitForOrientation(in: app, landscape: true)
    }

    private func waitForOrientation(in app: XCUIApplication, landscape: Bool) {
        let rotated = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > 0 && frame.height > 0 && (frame.width > frame.height) == landscape
        }
        waitForState(rotated, in: app, name: "Window orientation")
    }

    private func waitForStableControl(_ control: XCUIElement, in app: XCUIApplication) {
        var previous = CGRect.zero
        var changed = Date()
        let settled = NSPredicate { _, _ in
            // Read enabled state and geometry from one accessibility snapshot.
            // Separate queries can each block on a cold hosted simulator.
            guard let snapshot = try? control.snapshot(), snapshot.isEnabled,
                  snapshot.frame.width > 0, snapshot.frame.height > 0
            else {
                changed = Date()
                return false
            }
            let frame = snapshot.frame
            if frame != previous {
                previous = frame
                changed = Date()
            }
            return Date().timeIntervalSince(changed) >= 1 && control.isHittable
        }
        waitForState(settled, in: app, name: "Template control position")
    }

    private func selectTemplate(_ starter: XCUIElement, in app: XCUIApplication) {
        // Loading the community catalog can change the adaptive grid's columns.
        // Wait for that update before measuring a built-in template's position.
        let refresh = app.buttons["universe-refresh"].firstMatch
        waitForState(NSPredicate { _, _ in
            (try? refresh.snapshot().isEnabled) == true
        }, in: app, name: "Template catalog loading")
        waitForStableControl(starter, in: app)
        starter.tap()
    }

    private func focusEndOfShortDocument(_ editor: XCUIElement, in app: XCUIApplication) {
        editor.tap()
        waitForStableControl(editor, in: app)
        // These short fixtures fit above this point, even with the keyboard open.
        // Use touch positioning: XCTest hardware-key synthesis can get stuck
        // waiting for UIKit animations after both Cmd+A and Cmd+Down.
        let frame = editor.frame
        let keyboard = try? app.keyboards.firstMatch.snapshot()
        let bottom = keyboard.map { min(frame.maxY, $0.frame.minY) } ?? frame.maxY
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 2, dy: bottom - frame.minY - 20)).tap()
    }

    private func waitForState(
        _ predicate: NSPredicate,
        in app: XCUIApplication,
        of object: Any? = nil,
        name: String = "Expected state",
        timeout: TimeInterval = 30,
    ) {
        let completed = poll(timeout: timeout) { predicate.evaluate(with: object ?? app) }
        if !completed {
            capture(name)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = name + " hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            if name == "Window orientation" {
                diagnoseSystemRotation()
            }
        }
        expect(completed) == true
    }

    private func diagnoseSystemRotation() {
        guard !Self.capturedRotationFailure else {
            return
        }
        Self.capturedRotationFailure = true
        // A system app is an independent control: it distinguishes app layout
        // failures from simulator orientation delivery or system rotation lock.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = settings.windows.firstMatch.frame
            return frame.height > frame.width && frame.width > 0
        }, object: settings)
        let portraitReady = XCTWaiter.wait(for: [portrait], timeout: 5) == .completed
        let portraitFrame = settings.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = settings.windows.firstMatch.frame
            return frame.width > frame.height && frame.height > 0
        }, object: settings)
        let landscapeReady = XCTWaiter.wait(for: [landscape], timeout: 10) == .completed
        let report = "Settings control: portrait=\(portraitReady) \(portraitFrame), " +
            "landscape=\(landscapeReady) \(settings.windows.firstMatch.frame), " +
            "device=\(XCUIDevice.shared.orientation.rawValue)\n" + settings.debugDescription
        let attachment = XCTAttachment(string: report)
        attachment.name = "System rotation control"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture("System Settings after rotation")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
        let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let controls = XCTAttachment(string: springboard.debugDescription)
        controls.name = "Control Center diagnostic"
        controls.lifetime = .keepAlways
        add(controls)
        capture("Control Center diagnostic")
        XCUIDevice.shared.press(.home)
        settings.terminate()
    }

    private func expectShareSheet(in app: XCUIApplication) {
        // Verify our handoff to UIActivityViewController. The simulator's remote
        // extension can remain empty even after presentation; its app inventory
        // (including Save to Files) is outside this application's control.
        // TabletProjectTests validates the generated PDF before this handoff.
        let share = app.otherElements["ActivityListView"]
        let visible = appears(share, timeout: 30)
        if !visible {
            capture("Share sheet unavailable")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Share sheet hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        expect(visible) == true
    }

    private func reveal(_ element: XCUIElement, in form: XCUIElement, scrollingUp: Bool = true) {
        var visible = element.exists && element.isHittable
        for _ in 0 ..< 6 where !visible {
            if scrollingUp {
                form.swipeUp()
            } else {
                form.swipeDown()
            }
            visible = element.exists && element.isHittable
        }
        if !visible {
            capture("Subscription control unavailable")
            let hierarchy = XCTAttachment(string: form.debugDescription)
            hierarchy.name = "Subscription form hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        expect(visible) == true
    }

    func testSubscriptionPurchaseAndRestore() throws {
        let session = try XCTUnwrap(storeSession)
        session.clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en",
                               "-iPadCloudEnabled", "NO"]
        launchInLandscape(app)
        let banner = app.buttons["subscription-banner"].firstMatch
        if !appears(banner, timeout: 3) || !banner.isHittable {
            waitForStableControl(app.buttons["sidebar-toggle"].firstMatch, in: app)
            app.buttons["sidebar-toggle"].firstMatch.tap()
        }
        expect(appears(banner, timeout: 30)) == true
        banner.tap()
        let form = app.collectionViews["subscription-form"].firstMatch
        expect(appears(form, timeout: 30)) == true
        let restore = app.buttons["subscription-restore"].firstMatch
        reveal(restore, in: form)
        restore.tap()
        let noPurchases = app.staticTexts["No active subscription was found for this Apple Account."]
        reveal(noPurchases, in: form)
        let purchase = app.buttons["subscription-purchase"].firstMatch
        reveal(purchase, in: form, scrollingUp: false)
        // Introductory eligibility belongs to the Apple account's subscription group;
        // prior writing tests may already have consumed its introductory offer.
        expect(["Subscribe", "Start free trial"].contains(purchase.label)) == true
        capture("Monthly subscription")
        purchase.tap()
        reveal(app.staticTexts["subscription-status"].firstMatch, in: form, scrollingUp: false)
        waitForState(
            NSPredicate(format: "label BEGINSWITH %@", "Writing access until"),
            in: app,
            of: app.staticTexts["subscription-status"].firstMatch,
            timeout: 30,
        )
        app.buttons["Done"].tap()
        app.terminate()
        launchInLandscape(app)
        app.buttons["layout-writing"].firstMatch.tap()
        let editor = app.textViews["manuscript"].firstMatch
        expect(appears(editor, timeout: 10)) == true
        let original = editor.value as? String ?? ""
        let addition = "\nPurchased access survives relaunch.\n"
        editor.tap()
        editor.typeText(addition)
        let edited = editor.value as? String ?? ""
        expect(edited.contains(addition)) == true
        expect(edited.replacingOccurrences(of: addition, with: "")) == original
    }

    func testSubscriptionLegalLinks() throws {
        try XCTUnwrap(storeSession).clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en",
                               "-iPadCloudEnabled", "NO"]
        launchInLandscape(app)
        let banner = app.buttons["subscription-banner"].firstMatch
        if !appears(banner, timeout: 3) || !banner.isHittable {
            waitForStableControl(app.buttons["sidebar-toggle"].firstMatch, in: app)
            app.buttons["sidebar-toggle"].firstMatch.tap()
        }
        expect(appears(banner, timeout: 30)) == true
        banner.tap()
        let form = app.collectionViews["subscription-form"].firstMatch
        expect(appears(form, timeout: 30)) == true
        // Locate legal controls by their accessible names across supported runtimes.
        let privacy = form.descendants(matching: .any)["Privacy policy"].firstMatch
        reveal(privacy, in: form)
        expect(privacy.exists) == true
        let terms = form.descendants(matching: .any)["Terms of use"].firstMatch
        reveal(terms, in: form)
        expect(terms.exists) == true
    }

    func testExpiredSubscriptionProjectExport() throws {
        executionTimeAllowance = 180
        let session = try XCTUnwrap(storeSession)
        let app = startWriting()
        let banner = app.buttons["subscription-banner"].firstMatch
        let form = app.collectionViews["subscription-form"].firstMatch
        let restore = app.buttons["subscription-restore"].firstMatch
        let title = "Expired export " + UUID().uuidString.prefix(8)
        app.buttons["document-actions"].firstMatch.tap()
        app.buttons["Rename"].tap()
        let titleField = app.alerts.textFields.firstMatch
        titleField.tap()
        titleField.typeText(String(
            repeating: XCUIKeyboardKey.delete.rawValue,
            count: (titleField.value as? String)?.count ?? 0,
        ) + title)
        app.alerts.buttons["Save"].tap()
        app.textViews["manuscript"].firstMatch.tap()
        app.textViews["manuscript"].firstMatch.typeText("\nPreserved after subscription expiration.\n")
        waitForState(
            NSPredicate(format: "label == %@", "Saved"),
            in: app,
            of: app.staticTexts["save-status"].firstMatch,
            timeout: 30,
        )
        let manuscript = app.textViews["manuscript"].firstMatch.value as? String
        try session.expireSubscription(productIdentifier: "app.leftblank.writer.ipad.monthly")
        app.terminate()
        // Relaunch the existing library instead of seeding another document.
        if let seed = app.launchArguments.firstIndex(of: "-iPadOpenTemplate") {
            app.launchArguments.removeSubrange(seed ... seed + 1)
        }
        launchInLandscape(app)
        // Scene recovery can reopen the document. Reveal the library before opening settings.
        let libraryActions = app.buttons["library-actions"].firstMatch
        if !appears(libraryActions, timeout: 3) || !libraryActions.isHittable {
            waitForStableControl(app.buttons["sidebar-toggle"].firstMatch, in: app)
            app.buttons["sidebar-toggle"].firstMatch.tap()
        }
        expect(appears(libraryActions, timeout: 30)) == true
        libraryActions.tap()
        app.buttons["Settings"].tap()
        app.buttons["subscription-settings"].firstMatch.tap()
        expect(appears(form, timeout: 30)) == true
        // StoreKitTest's imperative expiration needs a sync to invalidate cached signed status.
        reveal(restore, in: form)
        restore.tap()
        reveal(app.staticTexts["subscription-status"].firstMatch, in: form, scrollingUp: false)
        waitForState(
            NSPredicate(format: "label BEGINSWITH %@", "Your subscription has expired"),
            in: app,
            of: app.staticTexts["subscription-status"].firstMatch,
            timeout: 30,
        )
        app.buttons["Done"].tap()
        expect(banner.exists) == true
        app.buttons["new-document"].firstMatch.tap()
        let starter = app.buttons["universe.builtin.blank"]
        selectTemplate(starter, in: app)
        expect(appears(form, timeout: 30)) == true
        expect(app.buttons["universe.builtin.blank"].exists) == false
        app.buttons["Done"].tap()
        waitForState(NSPredicate { _, _ in !form.exists }, in: app, name: "Subscription dismissal")
        app.collectionViews.staticTexts[title].firstMatch.tap()
        expect(appears(app.textViews["manuscript"].firstMatch, timeout: 30)) == true
        expect(app.textViews["manuscript"].firstMatch.value as? String) == manuscript
        app.buttons["document-actions"].firstMatch.tap()
        app.buttons["export-project"].firstMatch.tap()
        expectShareSheet(in: app)
        capture("Expired subscription project export")
    }

    func testWelcomePreviewAndPDFExport() {
        let app = startWriting(template: "welcome")
        capture("English writing")
        expect((app.textViews["manuscript"].firstMatch.value as? String)?.contains("leftblank-mark.svg")) == true
        app.buttons["layout-preview"].firstMatch.tap()
        waitForState(
            NSPredicate(format: "value == %@", "Preview Updated"),
            in: app,
            of: app.staticTexts["engine-status"].firstMatch,
            timeout: 60,
        )
        expect(app.buttons["preview-error"].firstMatch.exists) == false
        capture("Welcome rendered")
        let checks = app.buttons["check-source"].firstMatch
        expect(checks.frame.width) >= 44
        expect(checks.frame.height) >= 44
        checks.tap()
        expect(appears(app.navigationBars["Check Source"], timeout: 10)) == true
        expect(app.buttons.matching(NSPredicate(format: "value == %@", "error")).count) == 0
        expect(app.buttons["unknown font family: noto sans sc"].exists) == false
        capture("Welcome diagnostics")
        app.buttons["Done"].tap()
        app.buttons["document-actions"].firstMatch.tap()
        app.buttons["Export PDF…"].tap()
        expectShareSheet(in: app)
        capture("Welcome PDF sharing")
    }

    func testChineseWelcomePreview() {
        let app = startWriting(template: "welcome", language: "zh-Hans")
        expect((app.textViews["manuscript"].firstMatch.value as? String)?.contains("此中有真意")) == true
        app.buttons["layout-preview"].firstMatch.tap()
        waitForState(
            NSPredicate(format: "value == %@", "排版已更新"),
            in: app,
            of: app.staticTexts["engine-status"].firstMatch,
            timeout: 60,
        )
        expect(app.buttons["preview-error"].firstMatch.exists) == false
        capture("Chinese welcome rendered")
        app.buttons["check-source"].firstMatch.tap()
        expect(appears(app.navigationBars["检查源码"], timeout: 10)) == true
        expect(app.buttons.matching(NSPredicate(format: "value == %@", "error")).count) == 0
        expect(app.buttons["unknown font family: noto sans sc"].exists) == false
        capture("Chinese welcome diagnostics")
    }

    func testEditingPersistsAcrossPreviewAndRotation() {
        let app = startWriting()
        app.buttons["layout-preview"].firstMatch.tap()
        waitForState(
            NSPredicate(format: "value == %@", "Preview Updated"),
            in: app,
            of: app.staticTexts["engine-status"].firstMatch,
            timeout: 30,
        )
        app.buttons["layout-writing"].firstMatch.tap()
        let editor = app.textViews["manuscript"].firstMatch
        let original = editor.value as? String ?? ""
        let writing = "\n= iPad writing\nA shared local document.\n"
        focusEndOfShortDocument(editor, in: app)
        editor.typeText(writing)
        expect(editor.value as? String) == original + writing
        // Finish the edit before resizing the text view and its selection UI.
        waitForState(NSPredicate { _, _ in
            app.staticTexts["save-status"].firstMatch.label == "Saved" &&
                app.staticTexts["engine-status"].firstMatch.label == "Preview Updated"
        }, in: app, name: "Writing saved and rendered")
        app.buttons["layout-split"].firstMatch.tap()
        waitForStableControl(editor, in: app)
        focusEndOfShortDocument(editor, in: app)
        let split = "Edited in split view.\n"
        editor.typeText(split)
        expect(editor.value as? String) == original + writing + split
        let saved = NSPredicate(format: "label == %@", "Saved")
        waitForState(saved, in: app, of: app.staticTexts["save-status"].firstMatch, timeout: 30)
        let rendered = NSPredicate(format: "label == %@", "Preview Updated")
        waitForState(rendered, in: app, of: app.staticTexts["engine-status"].firstMatch, timeout: 60)
        app.buttons["layout-preview"].firstMatch.tap()
        expect(appears(app.webViews.firstMatch, timeout: 30)) == true
        waitForState(
            NSPredicate(format: "value == %@", "Preview Updated"),
            in: app,
            of: app.staticTexts["engine-status"].firstMatch,
            timeout: 20,
        )
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(in: app, landscape: false)
        app.buttons["layout-writing"].firstMatch.tap()
        expect(app.textViews["manuscript"].firstMatch.value as? String) == original + writing + split
        app.buttons["document-actions"].firstMatch.tap()
        app.buttons["Export PDF…"].tap()
        expectShareSheet(in: app)
    }

    func testAssistanceHistoryAndProjectNavigation() {
        executionTimeAllowance = 180
        let app = startWriting()
        let editor = app.textViews["manuscript"].firstMatch
        editor.tap()
        editor.typeText("\n#rec")
        let ready = NSPredicate { _, _ in
            ["Ready", "Preview Updated", "Document Needs Attention"]
                .contains(app.staticTexts["engine-status"].firstMatch.label)
        }
        waitForState(ready, in: app, name: "Typesetting ready for completion")
        // Suggestions must arrive while the native editor retains typing focus.
        let completion = app.buttons["completion-item-0"].firstMatch
        expect(appears(completion, timeout: 30)) == true
        capture("Native completion suggestions")
        let before = editor.value as? String
        completion.tap()
        waitForState(NSPredicate { _, _ in
            editor.exists && editor.value as? String != before
        }, in: app, name: "Completion inserted")
        app.buttons["commands"].firstMatch.tap()
        app.buttons["Undo"].tap()
        expect(editor.value as? String) == before
        app.buttons["document-actions"].firstMatch.tap()
        let history = app.buttons["Document History…"]
        waitForStableControl(history, in: app)
        history.tap()
        let revision = app.buttons["history-revision"].firstMatch
        expect(appears(revision, timeout: 15)) == true
        revision.tap()
        expect(appears(app.buttons["history-restore"].firstMatch, timeout: 15)) == true
        expect(app.staticTexts["Current writing"].exists) == true
        capture("History comparison")
        app.buttons["Back"].tap()
        expect(appears(app.navigationBars["Document History"], timeout: 10)) == true
        app.buttons["Done"].tap()
        app.buttons["document-actions"].firstMatch.tap()
        let files = app.buttons["project-files"].firstMatch
        waitForStableControl(files, in: app)
        files.tap()
        let entry = app.buttons["project-source-main.typ"].firstMatch
        expect(appears(entry, timeout: 10)) == true
        entry.tap()
        expect(appears(editor, timeout: 10)) == true
    }

    func testExistingProjectImageInsertionAndUndo() {
        let app = startWriting(template: "welcome")
        let editor = app.textViews["manuscript"].firstMatch
        let original = editor.value as? String
        app.buttons["commands"].firstMatch.tap()
        let search = app.searchFields["Search Commands"]
        expect(appears(search, timeout: 10)) == true
        search.tap()
        search.typeText("image\n")
        let image = app.buttons["command-image"].firstMatch
        expect(appears(image, timeout: 10)) == true
        image.tap()
        let resources = app.buttons["resource-existing"].firstMatch
        expect(appears(resources, timeout: 15)) == true
        resources.tap()
        app.buttons["leftblank-mark.svg"].tap()
        expect(app.buttons["Insert"].isEnabled) == true
        app.buttons["Insert"].tap()
        waitForState(NSPredicate { _, _ in
            editor.exists && editor.value as? String != original
        }, in: app, name: "Project image inserted")
        expect((editor.value as? String)?.components(separatedBy: "leftblank-mark.svg").count) == 3
        capture("Reused project image")
        app.buttons["commands"].firstMatch.tap()
        app.buttons["Undo"].tap()
        expect(editor.value as? String) == original
    }

    func testEditExistingTableAndUndo() {
        let app = startWriting()
        app.buttons["commands"].firstMatch.tap()
        let search = app.searchFields["Search Commands"]
        expect(appears(search, timeout: 10)) == true
        search.tap()
        search.typeText("table\n")
        let table = app.buttons["command-table"].firstMatch
        expect(appears(table, timeout: 10)) == true
        table.tap()
        app.buttons["Insert"].tap()
        let editor = app.textViews["manuscript"].firstMatch
        waitForState(NSPredicate { _, _ in
            (editor.value as? String)?.contains("#table(") == true
        }, in: app, name: "Table inserted")
        let original = editor.value as? String
        app.buttons["document-actions"].firstMatch.tap()
        app.buttons["edit-object"].firstMatch.tap()
        let addRow = app.buttons["object-add-row"].firstMatch
        expect(appears(addRow, timeout: 10)) == true
        addRow.tap()
        app.buttons["object-add-column"].firstMatch.tap()
        capture("Edit existing table")
        app.buttons["object-apply"].firstMatch.tap()
        waitForState(NSPredicate { _, _ in
            !app.buttons["object-apply"].firstMatch.exists && editor.value as? String != original
        }, in: app, name: "Table edit applied")
        let updated = editor.value as? String
        app.buttons["commands"].firstMatch.tap()
        app.buttons["Undo"].tap()
        expect(editor.value as? String) == original
        app.buttons["commands"].firstMatch.tap()
        app.buttons["Redo"].tap()
        expect(editor.value as? String) == updated
        waitForState(NSPredicate { _, _ in
            app.staticTexts["engine-status"].firstMatch.label == "Preview Updated"
        }, in: app, name: "Edited table compiled")
    }

    func testCommandInsertionAndPDFExport() {
        let app = startWriting()
        let original = app.textViews["manuscript"].firstMatch.value as? String
        app.buttons["commands"].firstMatch.tap()
        expect(appears(app.navigationBars["Discover Commands"], timeout: 10)) == true
        app.buttons["command-heading"].firstMatch.tap()
        app.buttons["Insert"].tap()
        let editor = app.textViews["manuscript"].firstMatch
        expect(appears(editor, timeout: 10)) == true
        expect((editor.value as? String)?.contains("=")) == true
        let inserted = editor.value as? String
        let commands = app.navigationBars["Discover Commands"]
        waitForState(
            NSPredicate { _, _ in !commands.exists && editor.isHittable },
            in: app,
            name: "Insertion panel dismissed",
        )
        app.buttons["commands"].firstMatch.tap()
        expect(appears(app.buttons["Undo"], timeout: 10)) == true
        app.buttons["Undo"].tap()
        waitForState(NSPredicate { _, _ in editor.value as? String == original }, in: app, timeout: 10)
        waitForState(
            NSPredicate { _, _ in !commands.exists && editor.isHittable },
            in: app,
            name: "Undo panel dismissed",
        )
        app.buttons["commands"].firstMatch.tap()
        expect(appears(app.buttons["Redo"], timeout: 10)) == true
        app.buttons["Redo"].tap()
        waitForState(NSPredicate { _, _ in editor.value as? String == inserted }, in: app, timeout: 10)
        let ready = NSPredicate(format: "label IN %@", ["Ready", "Preview Updated"])
        waitForState(ready, in: app, of: app.staticTexts["engine-status"].firstMatch, timeout: 60)
        app.buttons["document-actions"].firstMatch.tap()
        app.buttons["Export PDF…"].tap()
        expectShareSheet(in: app)
        capture("Command PDF sharing")
    }

    func testPreviewTapRevealsSourcePosition() {
        let app = startWriting(template: "welcome")
        let editor = app.textViews["manuscript"].firstMatch
        let source = editor.value as? String ?? ""
        let heading = "Ink for your thoughts"
        let sourceLine = source.components(separatedBy: "\n").firstIndex(of: "= " + heading)
        expect(sourceLine != nil) == true
        app.buttons["layout-preview"].firstMatch.tap()
        waitForState(
            NSPredicate(format: "label == %@ AND value == %@", "Preview Updated", "Preview Updated"),
            in: app,
            of: app.staticTexts["engine-status"].firstMatch,
            timeout: 60,
        )
        let preview = app.webViews.firstMatch
        expect(appears(preview, timeout: 10)) == true
        expect(app.buttons["preview-error"].firstMatch.exists) == false
        let renderedHeading = preview.staticTexts.matching(NSPredicate(
            format: "label == %@", heading,
        )).firstMatch
        expect(appears(renderedHeading, timeout: 15)) == true
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        renderedHeading.tap()
        let revealed = NSPredicate { _, _ in editor.isHittable }
        waitForState(revealed, in: app, timeout: 15)
        expect((app.staticTexts["source-position"].firstMatch.value as? String)?.hasPrefix("\(sourceLine ?? -1):")) ==
            true
        expect(editor.value as? String) == source
        let returning = app.buttons["preview-return"].firstMatch
        expect(appears(returning, timeout: 10)) == true
        expect(app.buttons.matching(identifier: "preview-return").count) == 1
        expect(app.buttons["preview-zoom-in"].firstMatch.exists) == false
        expect(returning.frame.width) >= 44
        expect(returning.frame.height) >= 44
        expect(returning.isEnabled) == true
        returning.tap()
        waitForState(
            NSPredicate { _, _ in !editor.isHittable && preview.isHittable },
            in: app,
            name: "Return to reading",
        )
        expect(app.buttons.matching(identifier: "preview-return").count) == 1
        app.buttons["preview-zoom-in"].firstMatch.tap()
        expect(appears(app.staticTexts["110%"], timeout: 10)) == true
        app.buttons["preview-zoom-out"].firstMatch.tap()
        expect(appears(app.staticTexts["100%"], timeout: 10)) == true
    }

    func testTemplateDiscoveryAndPackageImport() {
        let app = startWriting(gallery: true)
        let original = app.textViews["manuscript"].firstMatch.value as? String
        waitForStableControl(app.buttons["sidebar-toggle"].firstMatch, in: app)
        app.buttons["sidebar-toggle"].firstMatch.tap()
        expect(appears(app.staticTexts["library-title"].firstMatch, timeout: 10)) == true
        expect(app.staticTexts["library-title"].firstMatch.label) == "Your writing"
        capture("Library landscape")
        expect(app.buttons["Show Sidebar"].exists) == false
        app.buttons["library-actions"].firstMatch.tap()
        expect(appears(app.buttons["Settings"], timeout: 10)) == true
        capture("Library actions")
        app.buttons["Settings"].tap()
        expect(appears(app.navigationBars["Settings"], timeout: 10)) == true
        app.buttons["Done"].tap()
        app.buttons["new-document"].firstMatch.tap()
        expect(appears(app.navigationBars["Templates & Packages"], timeout: 10)) == true
        expect(app.navigationBars["Templates & Packages"].frame.width) > app.frame.width * 0.7
        capture("Templates landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(in: app, landscape: false)
        capture("Template storefront portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(in: app, landscape: true)
        let search = app.textFields["universe.search"].firstMatch
        expect(appears(search, timeout: 10)) == true
        expect(search.placeholderValue) == "Find a resume, paper, presentation…"
        waitForStableControl(search, in: app)
        search.tap()
        search.typeText("basic-resume")
        let resume = app.descendants(matching: .any)["universe.result.basic-resume"].firstMatch
        expect(appears(resume, timeout: 20)) == true
        search.typeText("\n")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(in: app, landscape: false)
        expect(appears(resume, timeout: 10)) == true
        expect(search.value as? String) == "basic-resume"
        capture("Templates portrait")
        resume.tap()
        let templateApply = app.buttons["universe.apply"].firstMatch
        expect(appears(templateApply, timeout: 10)) == true
        expect(templateApply.isHittable) == true
        expect(search.exists) == false
        capture("Template details portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(in: app, landscape: true)
        let landscape = NSPredicate { _, _ in
            templateApply.isHittable && search.isHittable && resume.isHittable
        }
        waitForState(landscape, in: app, timeout: 15)
        expect(templateApply.isHittable) == true
        expect(search.isHittable) == true
        expect(resume.isHittable) == true
        capture("Template details landscape")
        app.buttons["universe.back-results"].firstMatch.tap()
        expect(appears(search, timeout: 10)) == true
        expect(search.value as? String) == "basic-resume"
        app.buttons["universe.clear-search"].firstMatch.tap()
        app.buttons["Writing tools"].tap()
        expect(search.placeholderValue) == "Try diagrams, plots, code blocks…"
        capture("Packages landscape")
        waitForStableControl(search, in: app)
        search.tap()
        search.typeText("cetz")
        let package = app.descendants(matching: .any)["universe.result.cetz"].firstMatch
        expect(appears(package, timeout: 20)) == true
        search.typeText("\n")
        package.tap()
        let apply = app.buttons["universe.apply"].firstMatch
        expect(appears(apply, timeout: 10)) == true
        expect(apply.label) == "Insert Import"
        expect(search.isHittable) == true
        expect(package.isHittable) == true
        capture("Package details landscape")
        apply.tap()
        let editor = app.textViews["manuscript"].firstMatch
        let imported = NSPredicate { _, _ in
            editor.isHittable && (editor.value as? String)?.contains("#import \"@preview/cetz:") == true
        }
        waitForState(imported, in: app, timeout: 15)
        let source = editor.value as? String ?? ""
        let importLines = source.split(separator: "\n").filter { $0.hasPrefix("#import ") }
        expect(importLines.count) == 1
        expect(importLines.first?.hasSuffix("\"")) == true
        let preserved = source.split(separator: "\n").filter { !$0.hasPrefix("#import ") }
        expect(preserved) == (original ?? "").split(separator: "\n")
    }
}
