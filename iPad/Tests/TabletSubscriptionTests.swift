import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Nimble
import StoreKit
import StoreKitTest
import Testing
import UIKit
import XCTest
import ZIPFoundation

@MainActor
private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) {
        self.value = value
    }
}

@MainActor
private final class PurchaseFixture: TabletPurchaseService {
    var product = SubscriptionOffering(displayPrice: "$2.99", trialWeeks: 2)
    var current: SubscriptionAccess = .inactive
    var purchaseResult: SubscriptionPurchaseResult = .purchased
    var purchasedAccess: SubscriptionAccess?
    var productFailure: Error?
    var entitlementFailure: Error?
    var purchaseFailure: Error?
    var restoreFailure: Error?
    var purchases = 0
    var restores = 0
    var checks = 0
    var continuation: AsyncStream<Void>.Continuation?

    func offering() throws -> SubscriptionOffering {
        if let productFailure {
            throw productFailure
        }
        return product
    }

    func entitlement() throws -> SubscriptionAccess {
        checks += 1
        if let entitlementFailure {
            throw entitlementFailure
        }
        return current
    }

    func purchase() throws -> SubscriptionPurchaseResult {
        purchases += 1
        if let purchaseFailure {
            throw purchaseFailure
        }
        if let purchasedAccess {
            current = purchasedAccess
        }
        return purchaseResult
    }

    func restore() throws {
        restores += 1
        if let restoreFailure {
            throw restoreFailure
        }
    }

    func manage(in _: UIWindowScene) throws {
        throw FixtureError.failed
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation = $0 }
    }

    enum FixtureError: LocalizedError {
        case failed
        var errorDescription: String? {
            "Fixture failure"
        }
    }
}

@Suite(.serialized)
@MainActor
struct TabletSubscriptionTests {
    @Test func verifiedAccessExpiresWithoutDeletingDocuments() async {
        let fixture = PurchaseFixture()
        let deadline = Date().addingTimeInterval(3600)
        fixture.current = .subscribed(until: deadline)
        let clock = MutableDate(Date())
        let subscription = TabletSubscription(service: fixture, now: { clock.value })
        await subscription.refresh()
        #expect(subscription.canWrite)
        clock.value = deadline
        #expect(!subscription.canWrite)
        fixture.current = .expired
        await subscription.refresh()
        #expect(subscription.access == .expired)
    }

    @Test func gracePeriodAllowsWritingOnlyUntilVerifiedDeadline() async {
        let fixture = PurchaseFixture()
        let clock = MutableDate(Date())
        let deadline = clock.value.addingTimeInterval(3600)
        fixture.current = .gracePeriod(until: deadline)
        let subscription = TabletSubscription(service: fixture, now: { clock.value })
        await subscription.refresh()
        #expect(subscription.canWrite)
        clock.value = deadline
        #expect(!subscription.canWrite)
        fixture.current = .billingRetry
        await subscription.refresh()
        #expect(!subscription.canWrite)
        #expect(subscription.access == .billingRetry)
    }

    @Test func cancellationDoesNotGrantAccessOrShowAnError() async {
        let fixture = PurchaseFixture()
        fixture.purchaseResult = .cancelled
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        await subscription.purchase()
        #expect(fixture.purchases == 1)
        #expect(!subscription.canWrite)
        #expect(subscription.notice == nil)
        #expect(!subscription.working)
    }

    @Test func pendingPurchaseWaitsForVerifiedTransactionUpdate() async throws {
        let fixture = PurchaseFixture()
        fixture.purchaseResult = .pending
        let subscription = TabletSubscription(service: fixture)
        await subscription.start()
        let initialChecks = fixture.checks
        await subscription.start()
        #expect(fixture.checks == initialChecks)
        await subscription.purchase()
        #expect(subscription.notice == .pending)
        #expect(!subscription.canWrite)
        fixture.current = .subscribed(until: Date().addingTimeInterval(3600))
        fixture.continuation?.yield(())
        for _ in 0 ..< 100 where !subscription.canWrite {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(subscription.canWrite)
        fixture.current = .revoked
        fixture.continuation?.yield(())
        for _ in 0 ..< 100 where subscription.canWrite {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(subscription.access == .revoked)
        #expect(!subscription.canWrite)
    }

    @Test func successfulPurchaseRefreshesVerifiedEntitlementAndTrialEligibility() async {
        let fixture = PurchaseFixture()
        fixture.purchasedAccess = .subscribed(until: Date().addingTimeInterval(3600))
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        #expect(subscription.offering?.trialWeeks == 2)
        fixture.product = SubscriptionOffering(displayPrice: "€3.49", trialWeeks: nil)
        await subscription.purchase()
        #expect(subscription.canWrite)
        #expect(subscription.offering?.displayPrice == "€3.49")
        #expect(subscription.offering?.trialWeeks == nil)
    }

    @Test func catalogFailureRetainsVerifiedAccessAndPreventsUnknownPricePurchase() async {
        let fixture = PurchaseFixture()
        fixture.current = .subscribed(until: Date().addingTimeInterval(3600))
        fixture.productFailure = PurchaseFixture.FixtureError.failed
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        #expect(subscription.canWrite)
        #expect(subscription.offering == nil)
        #expect(subscription.productError == "Fixture failure")
        await subscription.purchase()
        #expect(fixture.purchases == 0)
        fixture.productFailure = nil
        await subscription.refresh()
        #expect(subscription.offering != nil)
        #expect(subscription.productError == nil)
    }

    @Test func unverifiedEntitlementAndPurchaseFailureDoNotUnlockWriting() async {
        let fixture = PurchaseFixture()
        fixture.entitlementFailure = PurchaseFixture.FixtureError.failed
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        #expect(!subscription.canWrite)
        #expect(subscription.notice == .failed("Fixture failure"))
        fixture.entitlementFailure = nil
        fixture.purchaseFailure = PurchaseFixture.FixtureError.failed
        await subscription.purchase()
        #expect(subscription.notice == .failed("Fixture failure"))
        #expect(!subscription.canWrite)
        #expect(!subscription.working)
    }

    @Test func restoreReportsActiveMissingAndFailedPurchases() async {
        let fixture = PurchaseFixture()
        let subscription = TabletSubscription(service: fixture)
        await subscription.restore()
        #expect(subscription.notice == .noPurchases)
        fixture.current = .subscribed(until: Date().addingTimeInterval(3600))
        await subscription.restore()
        #expect(subscription.notice == .restored)
        fixture.restoreFailure = PurchaseFixture.FixtureError.failed
        await subscription.restore()
        #expect(subscription.notice == .failed("Fixture failure"))
        #expect(!subscription.working)
        #expect(fixture.restores == 3)
    }

    @Test func expiredSnapshotCannotGrantAccess() async {
        let fixture = PurchaseFixture()
        fixture.current = .subscribed(until: Date().addingTimeInterval(-1))
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        #expect(subscription.access == .expired)
        #expect(!subscription.canWrite)
    }

    @Test func listenerAndExpirationTimerDoNotRetainOwner() async throws {
        let fixture = PurchaseFixture()
        fixture.current = .subscribed(until: Date().addingTimeInterval(3600))
        var subscription: TabletSubscription? = TabletSubscription(service: fixture)
        let owner = WeakReference(subscription)
        await subscription?.start()
        subscription = nil
        #expect(owner.value == nil)
        // Cancellation releases the AsyncStream continuation on the next executor turn.
        try await Task.sleep(for: .milliseconds(10))
        if case .terminated? = fixture.continuation?.yield(()) {
            #expect(owner.value == nil)
        } else {
            Issue.record("The released subscription must cancel its update listener")
        }
    }

    @Test func workspaceRejectsUnsubscribedMutationWithoutTouchingSource() async {
        let fixture = PurchaseFixture()
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        let workspace = TabletWorkspace(subscription: subscription)
        workspace.text = "Preserved manuscript"
        workspace.edited("Unexpected change", selection: NSRange(location: 0, length: 0))
        #expect(workspace.text == "Preserved manuscript")
        workspace.panel = .universe
        await workspace.create(.blank)
        #expect(workspace.document == nil)
        #expect(workspace.panel == .subscription)
        #expect(workspace.text == "Preserved manuscript")
        fixture.current = .subscribed(until: Date().addingTimeInterval(3600))
        await subscription.refresh()
        #expect(workspace.canWrite)
        fixture.current = .revoked
        await subscription.refresh()
        #expect(!workspace.canWrite)
        #expect(workspace.text == "Preserved manuscript")
    }

    @Test func editingBackToSavedContentFinishesAutosave() async throws {
        let service = PurchaseFixture()
        service.current = .subscribed(until: Date().addingTimeInterval(3600))
        let subscription = TabletSubscription(service: service)
        await subscription.refresh()
        let root = TestPaths.temporaryDirectory.appendingPathComponent("save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let original = "= Original\nSaved 中文😀\n"
        let document = try await workspace.library.create(text: original)
        let read = try await workspace.library.read(document.id)
        workspace.document = document
        workspace.activeSourceURL = document.sourceURL
        workspace.text = original
        workspace.savedText = original
        workspace.baseline = read.baseline
        workspace.edited("Temporary replacement", selection: NSRange(location: 0, length: 0))
        workspace.edited(original, selection: NSRange(location: 0, length: 0))
        let deadline = ContinuousClock.now + .seconds(3)
        while workspace.saveStatus != "Saved", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.saveStatus == "Saved")
        #expect(workspace.savedText == original)
        #expect(try DocumentStorage.read(document.sourceURL).0 == original)
        let recovery = try JSONDecoder().decode(RecoverySnapshot.self, from: Data(contentsOf: workspace.recoveryURL))
        #expect(recovery.text == original)
        #expect(recovery.savedText == original)
    }

    @Test func expiredWorkspaceExportsSavedSourceAndEveryProjectAsset() async throws {
        let fixture = PurchaseFixture()
        fixture.current = .subscribed(until: Date().addingTimeInterval(3600))
        let subscription = TabletSubscription(service: fixture)
        await subscription.refresh()
        let workspace = TabletWorkspace(subscription: subscription)
        await workspace.create(.welcome)
        let document = try #require(workspace.document)
        let manuscript = workspace.text + "\nExport ownership sentinel.\n"
        workspace.edited(manuscript, selection: NSRange(location: 0, length: 0))
        fixture.current = .expired
        await subscription.refresh()
        #expect(!workspace.canWrite)
        // Import and formatting cannot mutate an expired user's manuscript.
        await workspace.importDocument(document.sourceURL)
        await workspace.importProject(document.sourceURL.deletingLastPathComponent())
        await workspace.format()
        #expect(workspace.document?.id == document.id)
        #expect(workspace.text == manuscript)
        await workspace.exportProject()
        let archive = try #require(workspace.shareURL, "An expired subscriber can still export the complete project")
        let extracted = TestPaths.temporaryDirectory.appendingPathComponent("export-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: extracted)
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        }
        try FileManager.default.unzipItem(at: archive, to: extracted)
        let files = try #require(FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
        let source = try #require(files.first { $0.lastPathComponent == document.sourceURL.lastPathComponent })
        #expect(try String(contentsOf: source, encoding: .utf8) == manuscript)
        for (path, data) in try WelcomeDocument.assets() {
            let asset = try #require(files.first { $0.path.hasSuffix("/" + path) })
            #expect(try Data(contentsOf: asset) == data)
        }
        await workspace.trash(document)
    }

    @MainActor
    private final class MutableDate {
        var value: Date
        init(_ value: Date) {
            self.value = value
        }
    }
}

/// These cases exercise signed StoreKit transactions rather than granting a test entitlement.
@Suite(.serialized)
@MainActor
struct StoreKitSubscriptionTests {
    private func waitFor(_ subscription: TabletSubscription, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            await subscription.refresh()
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
    }

    @Test func realStoreKitTrialPurchaseRestoreExpiryAndRefund() async throws {
        let session = try SKTestSession(configurationFileNamed: "LeftBlank")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        // A cold simulator registers the test catalog asynchronously.
        var products: [Product] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            products = try await Product.products(for: [TabletSubscriptionConfiguration.productID])
            if !products.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        let product = try #require(
            products.first,
            "StoreKit must load the monthly product from the local configuration",
        )
        #expect(product.type == .autoRenewable)
        #expect(product.subscription?.subscriptionPeriod.unit == .month)
        #expect(product.subscription?.subscriptionPeriod.value == 1)
        #expect(product.subscription?.introductoryOffer?.period.unit == .week)
        #expect(product.subscription?.introductoryOffer?.period.value == 2)
        let service = StoreKitTabletPurchases()
        let subscription = TabletSubscription(service: service)
        await subscription.start()
        #expect(!subscription.canWrite)
        #expect(subscription.offering?.trialWeeks == 2)
        #expect(subscription.offering?.displayPrice.contains("2.99") == true)
        await subscription.purchase()
        try await waitFor(subscription) { subscription.canWrite }
        #expect(subscription.canWrite)
        try await waitFor(subscription) { subscription.offering?.trialWeeks == nil }
        #expect(subscription.offering?.trialWeeks == nil)
        await subscription.restore()
        #expect(subscription.notice == .restored)
        try session.expireSubscription(productIdentifier: TabletSubscriptionConfiguration.productID)
        // Sync after an imperative StoreKitTest change to invalidate its cached signed status.
        await subscription.restore()
        try await waitFor(subscription) { !subscription.canWrite }
        #expect(!subscription.canWrite)
        let transaction = try await session.buyProduct(identifier: TabletSubscriptionConfiguration.productID)
        try await waitFor(subscription) { subscription.canWrite }
        #expect(subscription.canWrite)
        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitFor(subscription) { subscription.access == .revoked }
        #expect(subscription.access == .revoked)
        #expect(!subscription.canWrite)
    }
}

@MainActor
final class TabletLifecycleTests: XCTestCase {
    func testRepeatedEmbeddedEngineLifecycleReleasesWorkerAndOwner() async throws {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("embedded-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0 ..< 4 {
            var engine: EmbeddedTinymist? = EmbeddedTinymist()
            let owner = WeakReference(engine)
            var status: Int32?
            engine?.onExit = { status = $0 }
            try engine?.start(root: root)
            expect(engine?.isRunning) == true
            engine?.stop()
            engine?.stop()
            expect(engine?.isRunning) == false
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while status == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            expect(status).toNot(beNil(), description: "The in-process Rust worker must finish after EOF")
            engine = nil
            expect(owner.value) == nil
        }
    }

    func testWorkspaceOwnershipMemory() {
        measure(metrics: [XCTMemoryMetric()]) {
            for _ in 0 ..< 30 {
                autoreleasepool {
                    let fixture = PurchaseFixture()
                    var workspace: TabletWorkspace? =
                        TabletWorkspace(subscription: TabletSubscription(service: fixture))
                    let owner = WeakReference(workspace)
                    workspace = nil
                    expect(owner.value) == nil
                }
            }
        }
    }
}
