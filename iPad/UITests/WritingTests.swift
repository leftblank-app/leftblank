import Nimble
import StoreKitTest
import XCTest

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

    private func startWriting(template: String = "blank", language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", language,
                               "-iPadCloudEnabled", "NO"]
        launchInLandscape(app)
        let create = app.buttons["new-document"]
        let actions = app.buttons["document-actions"]
        if actions.exists, actions.isHittable {
            // Fresh libraries open Welcome. Use its menu without waiting for
            // NavigationSplitView to reveal the sidebar after startup.
            actions.tap()
            let command = app.buttons[language == "zh-Hans" ? "新建文稿" : "New Document"]
            expect(command.waitForExistence(timeout: 60)) == true
            command.tap()
        } else {
            let enabled = NSPredicate { _, _ in create.exists && create.isEnabled && create.isHittable }
            expectation(for: enabled, evaluatedWith: app)
            waitForExpectations(timeout: 60)
            create.tap()
        }
        let starter = app.buttons["universe.builtin." + template]
        selectTemplate(starter, in: app)
        // An old manuscript remains in the hierarchy behind the gallery.
        // Require the creation flow to close it before accepting the editor.
        waitForState(NSPredicate { _, _ in !starter.exists }, in: app, name: "Template creation")
        expect(app.textViews["manuscript"].waitForExistence(timeout: 60)) == true
        let settled = NSPredicate { _, _ in !app.progressIndicators["document-loading"].exists }
        expectation(for: settled, evaluatedWith: app)
        waitForExpectations(timeout: 60)
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
        expect(app.windows.firstMatch.waitForExistence(timeout: 60)) == true
        // Scene restoration opens the engine and restores the caret asynchronously.
        // Finish that transition before rotating the editor and software keyboard.
        let loading = app.progressIndicators["document-loading"]
        let create = app.buttons["new-document"]
        let actions = app.buttons["document-actions"]
        let launched = NSPredicate { _, _ in
            !loading.exists && ((create.exists && create.isEnabled && create.isHittable) ||
                (actions.exists && actions.isHittable))
        }
        expectation(for: launched, evaluatedWith: app)
        waitForExpectations(timeout: 60)
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
        let refresh = app.buttons["universe-refresh"]
        waitForState(NSPredicate { _, _ in
            (try? refresh.snapshot().isEnabled) == true
        }, in: app, name: "Template catalog loading")
        waitForStableControl(starter, in: app)
        starter.tap()
    }

    private func waitForState(_ predicate: NSPredicate, in app: XCUIApplication, name: String) {
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: app)
        let completed = XCTWaiter.wait(for: [ready], timeout: 30) == .completed
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
        // The system sharing extension can still be loading on a cold hosted simulator.
        let share = app.descendants(matching: .any)["Save to Files"].firstMatch
        let visible = share.waitForExistence(timeout: 60)
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
        for _ in 0 ..< 6 {
            if element.exists, element.isHittable {
                return
            }
            if scrollingUp {
                form.swipeUp()
            } else {
                form.swipeDown()
            }
        }
        if !element.exists || !element.isHittable {
            capture("Subscription control unavailable")
            let hierarchy = XCTAttachment(string: form.debugDescription)
            hierarchy.name = "Subscription form hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        expect(element.exists && element.isHittable) == true
    }

    func testSubscriptionPurchaseAndRestore() throws {
        let session = try XCTUnwrap(storeSession)
        session.clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appLanguage", "en",
                               "-iPadCloudEnabled", "NO"]
        launchInLandscape(app)
        let banner = app.buttons["subscription-banner"]
        if !banner.waitForExistence(timeout: 3) || !banner.isHittable {
            waitForStableControl(app.buttons["sidebar-toggle"], in: app)
            app.buttons["sidebar-toggle"].tap()
        }
        expect(banner.waitForExistence(timeout: 30)) == true
        banner.tap()
        let form = app.collectionViews["subscription-form"]
        expect(form.waitForExistence(timeout: 30)) == true
        let restore = app.buttons["subscription-restore"]
        reveal(restore, in: form)
        restore.tap()
        let noPurchases = app.staticTexts["No active subscription was found for this Apple Account."]
        reveal(noPurchases, in: form)
        let purchase = app.buttons["subscription-purchase"]
        reveal(purchase, in: form, scrollingUp: false)
        // Introductory eligibility belongs to the Apple account's subscription group;
        // prior writing tests may already have consumed its introductory offer.
        expect(["Subscribe", "Start free trial"].contains(purchase.label)) == true
        capture("Monthly subscription")
        purchase.tap()
        reveal(app.staticTexts["subscription-status"], in: form, scrollingUp: false)
        expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "Writing access until"),
            evaluatedWith: app.staticTexts["subscription-status"],
        )
        waitForExpectations(timeout: 30)
        // Locate legal controls by their accessible names across supported runtimes.
        let privacy = app.descendants(matching: .any)["Privacy policy"].firstMatch
        reveal(privacy, in: form)
        expect(privacy.exists) == true
        let terms = app.descendants(matching: .any)["Terms of use"].firstMatch
        reveal(terms, in: form)
        expect(terms.exists) == true
        app.buttons["Done"].tap()
        app.terminate()
        let writer = startWriting()
        expect(writer.textViews["manuscript"].exists) == true
    }

    func testExpiredSubscriptionProjectExport() throws {
        executionTimeAllowance = 180
        let session = try XCTUnwrap(storeSession)
        let app = startWriting()
        let banner = app.buttons["subscription-banner"]
        let form = app.collectionViews["subscription-form"]
        let restore = app.buttons["subscription-restore"]
        let title = "Expired export " + UUID().uuidString.prefix(8)
        app.buttons["document-actions"].tap()
        app.buttons["Rename"].tap()
        let titleField = app.alerts.textFields.firstMatch
        titleField.tap()
        titleField.typeText(String(
            repeating: XCUIKeyboardKey.delete.rawValue,
            count: (titleField.value as? String)?.count ?? 0,
        ) + title)
        app.alerts.buttons["Save"].tap()
        app.textViews["manuscript"].tap()
        app.textViews["manuscript"].typeText("\nPreserved after subscription expiration.\n")
        expectation(for: NSPredicate(format: "label == %@", "Saved"), evaluatedWith: app.staticTexts["save-status"])
        waitForExpectations(timeout: 30)
        let manuscript = app.textViews["manuscript"].value as? String
        try session.expireSubscription(productIdentifier: "app.leftblank.writer.ipad.monthly")
        app.terminate()
        launchInLandscape(app)
        // Scene recovery can reopen the document. Reveal the library before opening settings.
        let libraryActions = app.buttons["library-actions"]
        if !libraryActions.waitForExistence(timeout: 3) || !libraryActions.isHittable {
            waitForStableControl(app.buttons["sidebar-toggle"], in: app)
            app.buttons["sidebar-toggle"].tap()
        }
        expect(libraryActions.waitForExistence(timeout: 30)) == true
        libraryActions.tap()
        app.buttons["Settings"].tap()
        app.buttons["subscription-settings"].tap()
        expect(form.waitForExistence(timeout: 30)) == true
        // StoreKitTest's imperative expiration needs a sync to invalidate cached signed status.
        reveal(restore, in: form)
        restore.tap()
        reveal(app.staticTexts["subscription-status"], in: form, scrollingUp: false)
        expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "Your subscription has expired"),
            evaluatedWith: app.staticTexts["subscription-status"],
        )
        waitForExpectations(timeout: 30)
        app.buttons["Done"].tap()
        expect(banner.exists) == true
        app.buttons["new-document"].tap()
        let starter = app.buttons["universe.builtin.blank"]
        selectTemplate(starter, in: app)
        expect(form.waitForExistence(timeout: 30)) == true
        expect(app.buttons["universe.builtin.blank"].exists) == false
        app.buttons["Done"].tap()
        waitForState(NSPredicate { _, _ in !form.exists }, in: app, name: "Subscription dismissal")
        app.collectionViews.staticTexts[title].firstMatch.tap()
        expect(app.textViews["manuscript"].waitForExistence(timeout: 30)) == true
        expect(app.textViews["manuscript"].value as? String) == manuscript
        app.buttons["document-actions"].tap()
        app.buttons["export-project"].tap()
        expectShareSheet(in: app)
        capture("Expired subscription project export")
    }

    func testWelcomePreviewAndPDFExport() {
        let app = startWriting(template: "welcome")
        capture("English writing")
        expect((app.textViews["manuscript"].value as? String)?.contains("leftblank-mark.svg")) == true
        app.buttons["layout-preview"].tap()
        expectation(
            for: NSPredicate(format: "value == %@", "Preview Updated"),
            evaluatedWith: app.staticTexts["engine-status"],
        )
        waitForExpectations(timeout: 60)
        expect(app.buttons["preview-error"].exists) == false
        capture("Welcome rendered")
        let checks = app.buttons["check-source"]
        expect(checks.frame.width) >= 44
        expect(checks.frame.height) >= 44
        checks.tap()
        expect(app.navigationBars["Check Source"].waitForExistence(timeout: 10)) == true
        expect(app.buttons.matching(NSPredicate(format: "value == %@", "error")).count) == 0
        expect(app.buttons["unknown font family: noto sans sc"].exists) == false
        capture("Welcome diagnostics")
        app.buttons["Done"].tap()
        app.buttons["document-actions"].tap()
        app.buttons["Export PDF…"].tap()
        expectShareSheet(in: app)
        capture("Welcome PDF sharing")
    }

    func testChineseWelcomePreview() {
        let app = startWriting(template: "welcome", language: "zh-Hans")
        expect((app.textViews["manuscript"].value as? String)?.contains("此中有真意")) == true
        app.buttons["layout-preview"].tap()
        expectation(
            for: NSPredicate(format: "value == %@", "排版已更新"),
            evaluatedWith: app.staticTexts["engine-status"],
        )
        waitForExpectations(timeout: 60)
        expect(app.buttons["preview-error"].exists) == false
        capture("Chinese welcome rendered")
        app.buttons["check-source"].tap()
        expect(app.navigationBars["检查源码"].waitForExistence(timeout: 10)) == true
        expect(app.buttons.matching(NSPredicate(format: "value == %@", "error")).count) == 0
        expect(app.buttons["unknown font family: noto sans sc"].exists) == false
        capture("Chinese welcome diagnostics")
    }

    func testEditingPersistsAcrossPreviewAndRotation() {
        let app = startWriting()
        app.buttons["layout-preview"].tap()
        expectation(
            for: NSPredicate(format: "value == %@", "Preview Updated"),
            evaluatedWith: app.staticTexts["engine-status"],
        )
        waitForExpectations(timeout: 30)
        app.buttons["layout-writing"].tap()
        let editor = app.textViews["manuscript"]
        editor.tap()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("= iPad writing\nA shared local document.\n")
        expect(editor.value as? String) == "= iPad writing\nA shared local document.\n"
        app.buttons["layout-split"].tap()
        editor.tap()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("= iPad writing\nA shared local document.\n")
        expect(editor.value as? String) == "= iPad writing\nA shared local document.\n"
        let saved = NSPredicate(format: "label == %@", "Saved")
        expectation(for: saved, evaluatedWith: app.staticTexts["save-status"])
        waitForExpectations(timeout: 30)
        let rendered = NSPredicate(format: "label == %@", "Preview Updated")
        expectation(for: rendered, evaluatedWith: app.staticTexts["engine-status"])
        waitForExpectations(timeout: 60)
        app.buttons["layout-preview"].tap()
        expect(app.webViews.firstMatch.waitForExistence(timeout: 30)) == true
        expectation(
            for: NSPredicate(format: "value == %@", "Preview Updated"),
            evaluatedWith: app.staticTexts["engine-status"],
        )
        waitForExpectations(timeout: 20)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(in: app, landscape: false)
        app.buttons["layout-writing"].tap()
        expect((app.textViews["manuscript"].value as? String)?.contains("iPad writing")) == true
        app.buttons["document-actions"].tap()
        app.buttons["Export PDF…"].tap()
        expectShareSheet(in: app)
    }

    func testAssistanceHistoryAndProjectNavigation() {
        executionTimeAllowance = 180
        let app = startWriting()
        let editor = app.textViews["manuscript"]
        editor.tap()
        editor.typeText("\n#rec")
        let ready = NSPredicate { _, _ in
            ["Ready", "Preview Updated", "Document Needs Attention"].contains(app.staticTexts["engine-status"].label)
        }
        waitForState(ready, in: app, name: "Typesetting ready for completion")
        // Suggestions must arrive while the native editor retains typing focus.
        let completion = app.buttons["completion-item-0"]
        expect(completion.waitForExistence(timeout: 30)) == true
        capture("Native completion suggestions")
        let before = editor.value as? String
        completion.tap()
        waitForState(NSPredicate { _, _ in
            editor.exists && editor.value as? String != before
        }, in: app, name: "Completion inserted")
        app.buttons["commands"].tap()
        app.buttons["Undo"].tap()
        expect(editor.value as? String) == before
        app.buttons["document-actions"].tap()
        let history = app.buttons["Document History…"]
        waitForStableControl(history, in: app)
        history.tap()
        let revision = app.buttons["history-revision"].firstMatch
        expect(revision.waitForExistence(timeout: 15)) == true
        revision.tap()
        expect(app.buttons["history-restore"].waitForExistence(timeout: 15)) == true
        expect(app.staticTexts["Current writing"].exists) == true
        capture("History comparison")
        app.buttons["Back"].tap()
        expect(app.navigationBars["Document History"].waitForExistence(timeout: 10)) == true
        app.buttons["Done"].tap()
        app.buttons["document-actions"].tap()
        let files = app.buttons["project-files"]
        waitForStableControl(files, in: app)
        files.tap()
        let entry = app.buttons["project-source-main.typ"]
        expect(entry.waitForExistence(timeout: 10)) == true
        entry.tap()
        expect(editor.waitForExistence(timeout: 10)) == true
    }

    func testExistingProjectImageInsertionAndUndo() {
        let app = startWriting(template: "welcome")
        let editor = app.textViews["manuscript"]
        let original = editor.value as? String
        app.buttons["commands"].tap()
        let search = app.searchFields["Search Commands"]
        expect(search.waitForExistence(timeout: 10)) == true
        search.tap()
        search.typeText("image\n")
        let image = app.buttons["command-image"]
        expect(image.waitForExistence(timeout: 10)) == true
        image.tap()
        let resources = app.buttons["resource-existing"]
        expect(resources.waitForExistence(timeout: 15)) == true
        resources.tap()
        app.buttons["leftblank-mark.svg"].tap()
        expect(app.buttons["Insert"].isEnabled) == true
        app.buttons["Insert"].tap()
        waitForState(NSPredicate { _, _ in
            editor.exists && editor.value as? String != original
        }, in: app, name: "Project image inserted")
        expect((editor.value as? String)?.components(separatedBy: "leftblank-mark.svg").count) == 3
        capture("Reused project image")
        app.buttons["commands"].tap()
        app.buttons["Undo"].tap()
        expect(editor.value as? String) == original
    }

    func testEditExistingTableAndUndo() {
        let app = startWriting()
        app.buttons["commands"].tap()
        let search = app.searchFields["Search Commands"]
        expect(search.waitForExistence(timeout: 10)) == true
        search.tap()
        search.typeText("table\n")
        let table = app.buttons["command-table"]
        expect(table.waitForExistence(timeout: 10)) == true
        table.tap()
        app.buttons["Insert"].tap()
        let editor = app.textViews["manuscript"]
        waitForState(NSPredicate { _, _ in
            (editor.value as? String)?.contains("#table(") == true
        }, in: app, name: "Table inserted")
        let original = editor.value as? String
        app.buttons["document-actions"].tap()
        app.buttons["edit-object"].tap()
        let addRow = app.buttons["object-add-row"]
        expect(addRow.waitForExistence(timeout: 10)) == true
        addRow.tap()
        app.buttons["object-add-column"].tap()
        capture("Edit existing table")
        app.buttons["object-apply"].tap()
        waitForState(NSPredicate { _, _ in
            !app.buttons["object-apply"].exists && editor.value as? String != original
        }, in: app, name: "Table edit applied")
        let updated = editor.value as? String
        app.buttons["commands"].tap()
        app.buttons["Undo"].tap()
        expect(editor.value as? String) == original
        app.buttons["commands"].tap()
        app.buttons["Redo"].tap()
        expect(editor.value as? String) == updated
        waitForState(NSPredicate { _, _ in
            app.staticTexts["engine-status"].label == "Preview Updated"
        }, in: app, name: "Edited table compiled")
    }

    func testCommandInsertionAndPDFExport() {
        let app = startWriting()
        let original = app.textViews["manuscript"].value as? String
        app.buttons["commands"].tap()
        expect(app.navigationBars["Discover Commands"].waitForExistence(timeout: 10)) == true
        app.buttons["command-heading"].tap()
        app.buttons["Insert"].tap()
        let editor = app.textViews["manuscript"]
        expect(editor.waitForExistence(timeout: 10)) == true
        expect((editor.value as? String)?.contains("=")) == true
        let inserted = editor.value as? String
        app.buttons["commands"].tap()
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate { _, _ in editor.value as? String == original }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.buttons["commands"].tap()
        app.buttons["Redo"].tap()
        expectation(for: NSPredicate { _, _ in editor.value as? String == inserted }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let ready = NSPredicate(format: "label IN %@", ["Ready", "Preview Updated"])
        expectation(for: ready, evaluatedWith: app.staticTexts["engine-status"])
        waitForExpectations(timeout: 60)
        app.buttons["document-actions"].tap()
        app.buttons["Export PDF…"].tap()
        expectShareSheet(in: app)
        capture("Command PDF sharing")
    }

    func testPreviewTapRevealsSourcePosition() {
        let app = startWriting(template: "welcome")
        let editor = app.textViews["manuscript"]
        let source = editor.value as? String ?? ""
        let heading = "Ink for your thoughts"
        let sourceLine = source.components(separatedBy: "\n").firstIndex(of: "= " + heading)
        expect(sourceLine != nil) == true
        app.buttons["layout-preview"].tap()
        expectation(
            for: NSPredicate(format: "label == %@ AND value == %@", "Preview Updated", "Preview Updated"),
            evaluatedWith: app.staticTexts["engine-status"],
        )
        waitForExpectations(timeout: 60)
        let preview = app.webViews.firstMatch
        expect(preview.waitForExistence(timeout: 10)) == true
        expect(app.buttons["preview-error"].exists) == false
        let renderedHeading = preview.staticTexts.matching(NSPredicate(
            format: "label == %@", heading,
        )).firstMatch
        expect(renderedHeading.waitForExistence(timeout: 15)) == true
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        renderedHeading.tap()
        let revealed = NSPredicate { _, _ in editor.isHittable }
        expectation(for: revealed, evaluatedWith: app)
        waitForExpectations(timeout: 15)
        expect((app.staticTexts["source-position"].value as? String)?.hasPrefix("\(sourceLine ?? -1):")) == true
        expect(editor.value as? String) == source
        let returning = app.buttons["preview-return"]
        expect(returning.waitForExistence(timeout: 10)) == true
        expect(app.buttons.matching(identifier: "preview-return").count) == 1
        expect(app.buttons["preview-zoom-in"].exists) == false
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
        app.buttons["preview-zoom-in"].tap()
        expect(app.staticTexts["110%"].waitForExistence(timeout: 10)) == true
        app.buttons["preview-zoom-out"].tap()
        expect(app.staticTexts["100%"].waitForExistence(timeout: 10)) == true
    }

    func testTemplateDiscoveryAndPackageImport() {
        let app = startWriting()
        let original = app.textViews["manuscript"].value as? String
        waitForStableControl(app.buttons["sidebar-toggle"], in: app)
        app.buttons["sidebar-toggle"].tap()
        expect(app.staticTexts["library-title"].waitForExistence(timeout: 10)) == true
        expect(app.staticTexts["library-title"].label) == "Your writing"
        capture("Library landscape")
        expect(app.buttons["Show Sidebar"].exists) == false
        app.buttons["library-actions"].tap()
        expect(app.buttons["Settings"].waitForExistence(timeout: 10)) == true
        capture("Library actions")
        app.buttons["Settings"].tap()
        expect(app.navigationBars["Settings"].waitForExistence(timeout: 10)) == true
        app.buttons["Done"].tap()
        app.buttons["new-document"].tap()
        expect(app.navigationBars["Templates & Packages"].waitForExistence(timeout: 10)) == true
        expect(app.navigationBars["Templates & Packages"].frame.width) > app.frame.width * 0.7
        capture("Templates landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(in: app, landscape: false)
        capture("Template storefront portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(in: app, landscape: true)
        let search = app.textFields["universe.search"]
        expect(search.waitForExistence(timeout: 10)) == true
        expect(search.placeholderValue) == "Find a resume, paper, presentation…"
        waitForStableControl(search, in: app)
        search.tap()
        search.typeText("basic-resume")
        let resume = app.descendants(matching: .any)["universe.result.basic-resume"].firstMatch
        expect(resume.waitForExistence(timeout: 20)) == true
        search.typeText("\n")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(in: app, landscape: false)
        expect(resume.waitForExistence(timeout: 10)) == true
        expect(search.value as? String) == "basic-resume"
        capture("Templates portrait")
        resume.tap()
        let templateApply = app.buttons["universe.apply"]
        expect(templateApply.waitForExistence(timeout: 10)) == true
        expect(templateApply.isHittable) == true
        expect(search.exists) == false
        capture("Template details portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(in: app, landscape: true)
        let landscape = NSPredicate { _, _ in
            templateApply.isHittable && search.isHittable && resume.isHittable
        }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 15)
        expect(templateApply.isHittable) == true
        expect(search.isHittable) == true
        expect(resume.isHittable) == true
        capture("Template details landscape")
        app.buttons["universe.back-results"].tap()
        expect(search.waitForExistence(timeout: 10)) == true
        expect(search.value as? String) == "basic-resume"
        app.buttons["universe.clear-search"].tap()
        app.buttons["Writing tools"].tap()
        expect(search.placeholderValue) == "Try diagrams, plots, code blocks…"
        capture("Packages landscape")
        waitForStableControl(search, in: app)
        search.tap()
        search.typeText("cetz")
        let package = app.descendants(matching: .any)["universe.result.cetz"].firstMatch
        expect(package.waitForExistence(timeout: 20)) == true
        search.typeText("\n")
        package.tap()
        let apply = app.buttons["universe.apply"]
        expect(apply.waitForExistence(timeout: 10)) == true
        expect(apply.label) == "Insert Import"
        expect(search.isHittable) == true
        expect(package.isHittable) == true
        capture("Package details landscape")
        apply.tap()
        let editor = app.textViews["manuscript"]
        let imported = NSPredicate { _, _ in
            editor.isHittable && (editor.value as? String)?.contains("#import \"@preview/cetz:") == true
        }
        expectation(for: imported, evaluatedWith: app)
        waitForExpectations(timeout: 15)
        let source = editor.value as? String ?? ""
        let importLines = source.split(separator: "\n").filter { $0.hasPrefix("#import ") }
        expect(importLines.count) == 1
        expect(importLines.first?.hasSuffix("\"")) == true
        let preserved = source.split(separator: "\n").filter { !$0.hasPrefix("#import ") }
        expect(preserved) == (original ?? "").split(separator: "\n")
    }
}
