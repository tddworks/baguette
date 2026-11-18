import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The three settings `xcrun simctl ui <udid> …` exposes — appearance,
/// increase-contrast and content size.
///
/// Each is its own value with a parser for what simctl *prints* and a
/// projection to what simctl *accepts*. Those two alphabets differ:
/// reading content size answers a category name, while setting it also
/// accepts `increment` / `decrement`. Keeping them apart is what stops
/// a read echoing back as an invalid write.
@Suite("Interface settings")
struct InterfaceSettingsTests {

    // MARK: - appearance

    @Test func `should read the appearance simctl prints`() {
        #expect(InterfaceAppearance(output: "light") == .light)
        #expect(InterfaceAppearance(output: "dark") == .dark)
    }

    @Test func `should read the appearance as unknown or unsupported, not a failure, when the device cannot answer`() {
        // A shut-down device answers "unknown" and exits 0 — asked
        // before boot, the honest answer is "I don't know", not an
        // error and certainly not a made-up "light".
        #expect(InterfaceAppearance(output: "unknown") == .unknown)
        #expect(InterfaceAppearance(output: "unsupported") == .unsupported)
    }

    @Test func `should tolerate the whitespace simctl leaves around an appearance`() {
        #expect(InterfaceAppearance(output: "dark\n") == .dark)
        #expect(InterfaceAppearance(output: "  light  ") == .light)
    }

    @Test func `should read an unrecognised appearance as unknown`() {
        #expect(InterfaceAppearance(output: "chartreuse") == .unknown)
        #expect(InterfaceAppearance(output: "") == .unknown)
    }

    @Test func `should only allow setting a real appearance`() {
        // `unknown` / `unsupported` are answers, never instructions —
        // there's no argv that means "make it unknown".
        #expect(InterfaceAppearance.dark.argument == "dark")
        #expect(InterfaceAppearance.light.argument == "light")
        #expect(InterfaceAppearance.unknown.argument == nil)
        #expect(InterfaceAppearance.unsupported.argument == nil)
    }

    @Test func `should flip the appearance for a toggle, but not when it is unknown`() {
        #expect(InterfaceAppearance.light.toggled == .dark)
        #expect(InterfaceAppearance.dark.toggled == .light)
        // Nothing to flip to when we don't know where we are.
        #expect(InterfaceAppearance.unknown.toggled == nil)
        #expect(InterfaceAppearance.unsupported.toggled == nil)
    }

    // MARK: - increase contrast

    @Test func `should read the contrast setting simctl prints`() {
        #expect(InterfaceContrast(output: "enabled") == .enabled)
        #expect(InterfaceContrast(output: "disabled\n") == .disabled)
        #expect(InterfaceContrast(output: "unsupported") == .unsupported)
        #expect(InterfaceContrast(output: "nonsense") == .unknown)
    }

    @Test func `should only allow setting a real contrast setting`() {
        #expect(InterfaceContrast.enabled.argument == "enabled")
        #expect(InterfaceContrast.disabled.argument == "disabled")
        #expect(InterfaceContrast.unknown.argument == nil)
    }

    @Test func `should flip the contrast setting, but not when it is unknown`() {
        #expect(InterfaceContrast.enabled.toggled == .disabled)
        #expect(InterfaceContrast.disabled.toggled == .enabled)
        #expect(InterfaceContrast.unknown.toggled == nil)
    }

    // MARK: - content size

    @Test func `should read every standard content size category`() {
        #expect(ContentSize(output: "extra-small") == .extraSmall)
        #expect(ContentSize(output: "small") == .small)
        #expect(ContentSize(output: "medium") == .medium)
        #expect(ContentSize(output: "large") == .large)
        #expect(ContentSize(output: "extra-large") == .extraLarge)
        #expect(ContentSize(output: "extra-extra-large") == .extraExtraLarge)
        #expect(ContentSize(output: "extra-extra-extra-large") == .extraExtraExtraLarge)
    }

    @Test func `should read the accessibility content size range`() {
        // The five accessibility sizes are the whole point of exposing
        // this to an a11y audit — they're where layouts break.
        #expect(ContentSize(output: "accessibility-medium") == .accessibilityMedium)
        #expect(ContentSize(output: "accessibility-large") == .accessibilityLarge)
        #expect(ContentSize(output: "accessibility-extra-large") == .accessibilityExtraLarge)
        #expect(ContentSize(output: "accessibility-extra-extra-large") == .accessibilityExtraExtraLarge)
        #expect(
            ContentSize(output: "accessibility-extra-extra-extra-large")
                == .accessibilityExtraExtraExtraLarge
        )
    }

    @Test func `should read back every settable content size from its wire name`() {
        // Every real size must project back to the exact token simctl
        // accepts, or setting what we just read would fail.
        for size in ContentSize.settable {
            #expect(ContentSize(output: size.argument ?? "") == size)
        }
    }

    @Test func `should read an unreadable content size as unknown`() {
        #expect(ContentSize(output: "unknown") == .unknown)
        #expect(ContentSize(output: "unsupported") == .unsupported)
        #expect(ContentSize(output: "gigantic") == .unknown)
    }

    @Test func `should offer the twelve real content sizes to set, smallest to largest`() {
        // Ordered smallest → largest so a UI can render them as a scale
        // and step through them.
        #expect(ContentSize.settable.count == 12)
        #expect(ContentSize.settable.first == .extraSmall)
        #expect(ContentSize.settable.last == .accessibilityExtraExtraExtraLarge)
        #expect(!ContentSize.settable.contains(.unknown))
        #expect(!ContentSize.settable.contains(.unsupported))
    }

    @Test func `should flag the accessibility content sizes as such`() {
        #expect(ContentSize.accessibilityLarge.isAccessibilitySize)
        #expect(!ContentSize.large.isAccessibilitySize)
    }

    // MARK: - changing content size

    @Test func `should spell a content-size change in simctl's setting alphabet`() {
        // Reading answers a category; setting also accepts relative
        // steps. Two alphabets, so two types.
        #expect(ContentSizeChange.increment.argument == "increment")
        #expect(ContentSizeChange.decrement.argument == "decrement")
        #expect(ContentSizeChange.size(.accessibilityLarge).argument == "accessibility-large")
    }

    @Test func `should read a content-size change from the wire`() {
        #expect(ContentSizeChange(wire: "increment") == .increment)
        #expect(ContentSizeChange(wire: "decrement") == .decrement)
        #expect(ContentSizeChange(wire: "extra-large") == .size(.extraLarge))
        #expect(ContentSizeChange(wire: "unknown") == nil)
        #expect(ContentSizeChange(wire: "nonsense") == nil)
    }

    @Test func `should name no argument for a content-size change to a read-only size`() {
        // `.size(.unknown)` is constructible in-module, and silently
        // spelling it `large` would set the device to an unrelated
        // category. No argument means the setter refuses instead —
        // matching how appearance and contrast already behave.
        #expect(ContentSizeChange.size(.unknown).argument == nil)
        #expect(ContentSizeChange.size(.unsupported).argument == nil)
    }
}
