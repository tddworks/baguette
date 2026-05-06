import Testing
import Foundation
import CoreGraphics
@testable import Baguette

/// Unit tests for the static element-reading helpers on
/// `AXPTranslatorAccessibility`. These extract values out of the
/// `AXPMacPlatformElement` returned by AXPTranslator's XPC round-
/// trip; the production calls hand a real ObjC element in. Here
/// we drive the same helpers with `FakeAXElement` — an `NSObject`
/// subclass that overrides the KVC / selector surface — so the
/// helper logic can be exercised without a booted simulator.
@Suite("AXPTranslatorAccessibility element extractors")
struct AXPElementExtractorTests {

    // MARK: - stringValue

    @Test func `stringValue returns the property when non-empty`() {
        let elem = FakeAXElement(strings: ["accessibilityRole": "AXButton"])
        #expect(AXPTranslatorAccessibility.stringValue(elem, "accessibilityRole") == "AXButton")
    }

    @Test func `stringValue returns nil for empty strings`() {
        let elem = FakeAXElement(strings: ["accessibilityLabel": ""])
        #expect(AXPTranslatorAccessibility.stringValue(elem, "accessibilityLabel") == nil)
    }

    @Test func `stringValue returns nil for missing keys`() {
        let elem = FakeAXElement()
        #expect(AXPTranslatorAccessibility.stringValue(elem, "accessibilityRole") == nil)
    }

    @Test func `stringValue returns nil when the value is not a string`() {
        let elem = FakeAXElement(numbers: ["accessibilityRole": NSNumber(value: 42)])
        #expect(AXPTranslatorAccessibility.stringValue(elem, "accessibilityRole") == nil)
    }

    // MARK: - stringValueOrNumber

    @Test func `stringValueOrNumber returns string properties verbatim`() {
        let elem = FakeAXElement(strings: ["accessibilityValue": "Wednesday"])
        #expect(AXPTranslatorAccessibility.stringValueOrNumber(elem, "accessibilityValue") == "Wednesday")
    }

    @Test func `stringValueOrNumber stringifies NSNumber slider values`() {
        let elem = FakeAXElement(numbers: ["accessibilityValue": NSNumber(value: 0.75)])
        #expect(AXPTranslatorAccessibility.stringValueOrNumber(elem, "accessibilityValue") == "0.75")
    }

    @Test func `stringValueOrNumber returns nil for empty strings`() {
        let elem = FakeAXElement(strings: ["accessibilityValue": ""])
        #expect(AXPTranslatorAccessibility.stringValueOrNumber(elem, "accessibilityValue") == nil)
    }

    @Test func `stringValueOrNumber returns nil when the key is missing`() {
        #expect(AXPTranslatorAccessibility.stringValueOrNumber(FakeAXElement(), "k") == nil)
    }

    // MARK: - boolValue

    @Test func `boolValue returns the wrapped NSNumber's boolValue when present`() {
        let truthy = FakeAXElement(numbers: ["accessibilityEnabled": NSNumber(value: true)])
        let falsy  = FakeAXElement(numbers: ["accessibilityEnabled": NSNumber(value: false)])
        #expect(AXPTranslatorAccessibility.boolValue(truthy, "accessibilityEnabled", default: false) == true)
        #expect(AXPTranslatorAccessibility.boolValue(falsy,  "accessibilityEnabled", default: true)  == false)
    }

    @Test func `boolValue returns the fallback when the key is missing`() {
        let elem = FakeAXElement()
        #expect(AXPTranslatorAccessibility.boolValue(elem, "absent", default: true) == true)
        #expect(AXPTranslatorAccessibility.boolValue(elem, "absent", default: false) == false)
    }

    @Test func `boolValue returns the fallback when the value is not an NSNumber`() {
        let elem = FakeAXElement(strings: ["weird": "true"])
        #expect(AXPTranslatorAccessibility.boolValue(elem, "weird", default: false) == false)
    }

    // MARK: - devicePointSize

    @Test func `devicePointSize divides mainScreenSize by mainScreenScale`() {
        let device = FakeSimDeviceWithType(
            pixelSize: CGSize(width: 1206, height: 2622),
            scale: 3.0
        )
        let size = AXPTranslatorAccessibility.devicePointSize(for: device)
        #expect(size.width == 402)
        #expect(size.height == 874)
    }

    @Test func `devicePointSize accepts NSValue-wrapped CGSize`() {
        let device = FakeSimDeviceWithType(
            pixelSizeAsValue: NSValue(size: NSSize(width: 786, height: 1704)),
            scale: 2.0
        )
        let size = AXPTranslatorAccessibility.devicePointSize(for: device)
        #expect(size.width == 393)
        #expect(size.height == 852)
    }

    @Test func `devicePointSize falls back when deviceType is missing`() {
        let device = FakeSimDeviceWithType()  // no deviceType at all
        let fallback = AXPTranslatorAccessibility.devicePointSize(for: device)
        // Sensible iPhone-class default — the production code's
        // `fallback` line. Unit tests treat it as "any positive
        // size" rather than pinning the exact constant, so the
        // adapter can tune the default later without breaking us.
        #expect(fallback.width  > 0)
        #expect(fallback.height > 0)
    }

    @Test func `devicePointSize falls back when scale is zero`() {
        let device = FakeSimDeviceWithType(
            pixelSize: CGSize(width: 1206, height: 2622),
            scale: 0.0  // bogus
        )
        let size = AXPTranslatorAccessibility.devicePointSize(for: device)
        #expect(size.width  > 0)
        #expect(size.height > 0)
    }

    @Test func `devicePointSize falls back when mainScreenSize is missing`() {
        // deviceType is present but doesn't carry the screen size.
        let device = FakeSimDeviceWithType(scale: 3.0)
        let size = AXPTranslatorAccessibility.devicePointSize(for: device)
        #expect(size.width  > 0)
        #expect(size.height > 0)
    }

    // MARK: - frame(of:)

    @Test func `frame returns zero when the element doesn't respond to accessibilityFrame`() {
        let elem = FakeAXElement()
        #expect(AXPTranslatorAccessibility.frame(of: elem) == .zero)
    }
}

// MARK: - Test fakes

/// `NSObject` subclass that overrides KVC for an arbitrary set of
/// keys. Used by the extractor tests to drive `stringValue` /
/// `stringValueOrNumber` / `boolValue` against deterministic data
/// without going anywhere near the real `AXPMacPlatformElement`
/// type.
final class FakeAXElement: NSObject {
    private let strings: [String: String]
    private let numbers: [String: NSNumber]
    private let any: [String: Any]

    init(
        strings: [String: String] = [:],
        numbers: [String: NSNumber] = [:],
        any: [String: Any] = [:]
    ) {
        self.strings = strings
        self.numbers = numbers
        self.any = any
        super.init()
    }

    override func value(forKey key: String) -> Any? {
        if let s = strings[key] { return s }
        if let n = numbers[key] { return n }
        if let a = any[key]     { return a }
        return nil
    }
}

/// `NSObject` subclass mimicking just enough of `SimDevice` for the
/// `devicePointSize(for:)` helper to chew through it. Carries an
/// inner `deviceType` that itself overrides KVC for
/// `mainScreenSize` / `mainScreenScale`.
final class FakeSimDeviceWithType: NSObject {
    private let deviceType: FakeDeviceType?

    init(
        pixelSize: CGSize? = nil,
        pixelSizeAsValue: NSValue? = nil,
        scale: Double? = nil
    ) {
        if pixelSize == nil && pixelSizeAsValue == nil && scale == nil {
            self.deviceType = nil
        } else {
            self.deviceType = FakeDeviceType(
                pixelSize: pixelSize,
                pixelSizeAsValue: pixelSizeAsValue,
                scale: scale
            )
        }
        super.init()
    }

    override func value(forKey key: String) -> Any? {
        if key == "deviceType" { return deviceType }
        return super.value(forKey: key)
    }
}

final class FakeDeviceType: NSObject {
    private let pixelSize: CGSize?
    private let pixelSizeAsValue: NSValue?
    private let scale: Double?

    init(pixelSize: CGSize?, pixelSizeAsValue: NSValue?, scale: Double?) {
        self.pixelSize = pixelSize
        self.pixelSizeAsValue = pixelSizeAsValue
        self.scale = scale
        super.init()
    }

    override func value(forKey key: String) -> Any? {
        switch key {
        case "mainScreenSize":
            // Production reads CGSize first, then falls back to
            // NSValue. Mirror that so each branch is exercised.
            if let cg = pixelSize { return cg }
            if let nsv = pixelSizeAsValue { return nsv }
            return nil
        case "mainScreenScale":
            return scale.map { NSNumber(value: $0) }
        default:
            return nil
        }
    }
}
