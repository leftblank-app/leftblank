import CoreGraphics
import Foundation
import LeftBlankCore
import Testing

struct SplitLayoutTests {
    @Test func ratiosStayWithinTheSupportedRange() {
        #expect(SplitLayout.clamped(0.5) == 0.5)
        #expect(SplitLayout.clamped(0.05) == SplitLayout.fractionRange.lowerBound)
        #expect(SplitLayout.clamped(0.95) == SplitLayout.fractionRange.upperBound)
        #expect(SplitLayout.clamped(.nan) == SplitLayout.defaultFraction)
        #expect(SplitLayout.clamped(.infinity) == SplitLayout.defaultFraction)
    }

    @Test func editorWidthFollowsTheRatioAndKeepsMinimumPanes() {
        // A 1220 pt window has a 1 pt divider between the panes.
        #expect(SplitLayout.editorWidth(in: 1221, fraction: 0.5, divider: 1) == 610)
        #expect(SplitLayout.editorWidth(in: 1221, fraction: 0.6, divider: 1) == 732)
        // The 20% limit would leave a 244 pt editor; the minimum pane wins.
        #expect(SplitLayout.editorWidth(in: 1221, fraction: 0.2, divider: 1) == 280)
        #expect(SplitLayout.editorWidth(in: 1221, fraction: 0.8, divider: 1) == 940, "1220 minus the 280 pt preview")
        // Out-of-range ratios are clamped before minimum widths apply.
        #expect(SplitLayout.editorWidth(in: 2561, fraction: 0.01, divider: 1) == 512)
        #expect(SplitLayout.editorWidth(in: 2561, fraction: 2, divider: 1) == 2048)
    }

    @Test func narrowAreasSplitEvenlyInsteadOfOverflowing() {
        #expect(SplitLayout.editorWidth(in: 500, fraction: 0.8) == 250)
        #expect(SplitLayout.editorWidth(in: 500, fraction: 0.2) == 250)
        #expect(SplitLayout.editorWidth(in: 561, fraction: 0.2, divider: 1) == 280)
        #expect(SplitLayout.editorWidth(in: 0, fraction: 0.6) == 0)
        #expect(SplitLayout.editorWidth(in: 1, fraction: 0.6, divider: 1) == 0)
        #expect(SplitLayout.fraction(editorWidth: 0, in: 0) == SplitLayout.defaultFraction)
    }

    @Test func ratioIsKeptWhenTheWindowResizes() {
        let fraction = SplitLayout.fraction(editorWidth: 488, in: 1221, divider: 1)
        #expect(abs(fraction - 0.4) < 0.001)
        #expect(SplitLayout.editorWidth(in: 1221, fraction: fraction, divider: 1) == 488)
        #expect(SplitLayout.editorWidth(in: 2001, fraction: fraction, divider: 1) == 800)
        #expect(SplitLayout.editorWidth(in: 821, fraction: fraction, divider: 1) == 328)
    }

    @Test func adjustmentsStepFromTheVisibleDivider() {
        #expect(abs(SplitLayout.adjusted(by: 1, editorWidth: 600, in: 1200) - 0.55) < 0.001)
        #expect(abs(SplitLayout.adjusted(by: -2, editorWidth: 600, in: 1200) - 0.4) < 0.001)
        // A minimum pane holds a stored 20% ratio at 280 of 1000 points; one
        // increment must move the visible divider rather than the hidden ratio.
        let increment = SplitLayout.adjusted(by: 1, editorWidth: 280, in: 1000)
        #expect(abs(increment - 0.33) < 0.001)
        #expect(SplitLayout.editorWidth(in: 1000, fraction: increment) > 280)
        #expect(SplitLayout.adjusted(by: 10, editorWidth: 790, in: 1000) == SplitLayout.fractionRange.upperBound)
    }

    @Test func storedRatioIsValidatedAndPerDevice() throws {
        let suite = "LeftBlank.split.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SplitLayout.storedFraction(in: defaults) == SplitLayout.defaultFraction)
        SplitLayout.store(0.65, in: defaults)
        #expect(abs(SplitLayout.storedFraction(in: defaults) - 0.65) < 0.0001)
        SplitLayout.store(3, in: defaults)
        #expect(SplitLayout.storedFraction(in: defaults) == SplitLayout.fractionRange.upperBound)
        defaults.set("wide", forKey: SplitLayout.storageKey)
        #expect(SplitLayout.storedFraction(in: defaults) == SplitLayout.defaultFraction)
        // The ratio describes this screen, so it never joins synced preferences.
        let synced = try String(decoding: JSONEncoder().encode(SyncedPreferences()), as: UTF8.self)
        #expect(!synced.contains("split"))
    }
}
