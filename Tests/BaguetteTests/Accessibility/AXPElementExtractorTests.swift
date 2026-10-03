import CoreGraphics
import Foundation
import Testing

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
        #expect(AXElementReader.string(elem, "accessibilityRole") == "AXButton")
    }

    @Test func `stringValue returns nil for empty strings`() {
        let elem = FakeAXElement(strings: ["accessibilityLabel": ""])
        #expect(AXElementReader.string(elem, "accessibilityLabel") == nil)
    }

    @Test func `stringValue returns nil for missing keys`() {
        let elem = FakeAXElement()
        #expect(AXElementReader.string(elem, "accessibilityRole") == nil)
    }

    @Test func `stringValue returns nil when the value is not a string`() {
        let elem = FakeAXElement(numbers: ["accessibilityRole": NSNumber(value: 42)])
        #expect(AXElementReader.string(elem, "accessibilityRole") == nil)
    }

    // MARK: - stringValueOrNumber

    @Test func `stringValueOrNumber returns string properties verbatim`() {
        let elem = FakeAXElement(strings: ["accessibilityValue": "Wednesday"])
        #expect(AXElementReader.stringOrNumber(elem, "accessibilityValue") == "Wednesday")
    }

    @Test func `stringValueOrNumber stringifies NSNumber slider values`() {
        let elem = FakeAXElement(numbers: ["accessibilityValue": NSNumber(value: 0.75)])
        #expect(AXElementReader.stringOrNumber(elem, "accessibilityValue") == "0.75")
    }

    @Test func `stringValueOrNumber returns nil for empty strings`() {
        let elem = FakeAXElement(strings: ["accessibilityValue": ""])
        #expect(AXElementReader.stringOrNumber(elem, "accessibilityValue") == nil)
    }

    @Test func `stringValueOrNumber returns nil when the key is missing`() {
        #expect(AXElementReader.stringOrNumber(FakeAXElement(), "k") == nil)
    }

    // MARK: - boolValue

    @Test func `boolValue returns the wrapped NSNumber's boolValue when present`() {
        let truthy = FakeAXElement(numbers: ["accessibilityEnabled": NSNumber(value: true)])
        let falsy = FakeAXElement(numbers: ["accessibilityEnabled": NSNumber(value: false)])
        #expect(AXElementReader.bool(truthy, "accessibilityEnabled", default: false) == true)
        #expect(AXElementReader.bool(falsy, "accessibilityEnabled", default: true) == false)
    }

    @Test func `boolValue returns the fallback when the key is missing`() {
        let elem = FakeAXElement()
        #expect(AXElementReader.bool(elem, "absent", default: true) == true)
        #expect(AXElementReader.bool(elem, "absent", default: false) == false)
    }

    @Test func `boolValue returns the fallback when the value is not an NSNumber`() {
        let elem = FakeAXElement(strings: ["weird": "true"])
        #expect(AXElementReader.bool(elem, "weird", default: false) == false)
    }

    // MARK: - frame(of:)

    @Test func `frame returns zero when the element doesn't respond to accessibilityFrame`() {
        let elem = FakeAXElement()
        #expect(AXElementReader.frame(of: elem) == .zero)
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
        if let a = any[key] { return a }
        return nil
    }
}
