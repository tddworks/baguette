import CoreGraphics
import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDevice

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

    @Test func `should read a non-empty text attribute`() {
        let elem = FakeAXElement(strings: ["accessibilityRole": "AXButton"])
        #expect(AXElementReader.string(elem, "accessibilityRole") == "AXButton")
    }

    @Test func `should leave a text attribute unset when it is empty`() {
        let elem = FakeAXElement(strings: ["accessibilityLabel": ""])
        #expect(AXElementReader.string(elem, "accessibilityLabel") == nil)
    }

    @Test func `should leave a text attribute unset when it is missing`() {
        let elem = FakeAXElement()
        #expect(AXElementReader.string(elem, "accessibilityRole") == nil)
    }

    @Test func `should leave a text attribute unset when it is not text`() {
        let elem = FakeAXElement(numbers: ["accessibilityRole": NSNumber(value: 42)])
        #expect(AXElementReader.string(elem, "accessibilityRole") == nil)
    }

    // MARK: - stringValueOrNumber

    @Test func `should read a text value verbatim`() {
        let elem = FakeAXElement(strings: ["accessibilityValue": "Wednesday"])
        #expect(AXElementReader.stringOrNumber(elem, "accessibilityValue") == "Wednesday")
    }

    @Test func `should read a numeric slider value as text`() {
        let elem = FakeAXElement(numbers: ["accessibilityValue": NSNumber(value: 0.75)])
        #expect(AXElementReader.stringOrNumber(elem, "accessibilityValue") == "0.75")
    }

    @Test func `should leave a value unset when it is empty text`() {
        let elem = FakeAXElement(strings: ["accessibilityValue": ""])
        #expect(AXElementReader.stringOrNumber(elem, "accessibilityValue") == nil)
    }

    @Test func `should leave a value unset when it is missing`() {
        #expect(AXElementReader.stringOrNumber(FakeAXElement(), "k") == nil)
    }

    // MARK: - boolValue

    @Test func `should read a flag as reported when it is present`() {
        let truthy = FakeAXElement(numbers: ["accessibilityEnabled": NSNumber(value: true)])
        let falsy = FakeAXElement(numbers: ["accessibilityEnabled": NSNumber(value: false)])
        #expect(AXElementReader.bool(truthy, "accessibilityEnabled", default: false) == true)
        #expect(AXElementReader.bool(falsy, "accessibilityEnabled", default: true) == false)
    }

    @Test func `should use the fallback for a flag when it is missing`() {
        let elem = FakeAXElement()
        #expect(AXElementReader.bool(elem, "absent", default: true) == true)
        #expect(AXElementReader.bool(elem, "absent", default: false) == false)
    }

    @Test func `should use the fallback for a flag when it is not a number`() {
        let elem = FakeAXElement(strings: ["weird": "true"])
        #expect(AXElementReader.bool(elem, "weird", default: false) == false)
    }

    // MARK: - frame(of:)

    @Test func `should give a zero frame when the element reports no frame`() {
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
