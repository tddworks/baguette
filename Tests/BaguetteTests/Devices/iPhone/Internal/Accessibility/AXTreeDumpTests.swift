import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Stands in for AccessibilityPlatformTranslation's objects: answers KVC
/// from a dictionary, as `AXPTranslatorResponse` / `AXPTranslationObject` do.
private final class FakeAX: NSObject {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    override func value(forKey key: String) -> Any? { values[key] }
}

@Suite("AXTreeDump")
struct AXTreeDumpTests {
    private let app = FakeAX(["pid": NSNumber(value: 812), "objectID": NSNumber(value: 1)])
    private let button = FakeAX(["pid": NSNumber(value: 812), "objectID": NSNumber(value: 42)])

    private func envelope(_ kind: String, _ records: [NSObject]) -> FakeAX {
        FakeAX(["resultData": ["treeDumpType": kind, "treeDump": records] as NSDictionary])
    }

    private let records: [NSObject]

    init() {
        let (app, button) = (app, button)
        records = [
            FakeAX(["associatedRequestType": NSNumber(value: 4), "translationResponse": app]),
            FakeAX(["associatedRequestType": NSNumber(value: 5), "associatedTranslationObject": button,
                    "resultData": [NSNumber(value: 2001): "New Project", NSNumber(value: 2002): "AXButton"] as NSDictionary]),
            FakeAX(["associatedRequestType": NSNumber(value: 2), "attribute": NSNumber(value: 2005),
                    "associatedTranslationObject": button, "resultData": NSNumber(value: true)]),
            FakeAX(["associatedRequestType": NSNumber(value: 3), "attribute": NSNumber(value: 2001),
                    "associatedTranslationObject": button]),
            FakeAX(["associatedRequestType": NSNumber(value: 2), "attribute": NSNumber(value: 7)]),
        ]
    }

    @Test func `should take the app the phone's tree starts from`() throws {
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", records)))

        #expect(dump.root === app)
        #expect(dump.isComplete)
    }

    @Test func `should know the first of the phone's two pushes isn't the whole tree`() throws {
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeInitialDump", records)))

        #expect(!dump.isComplete)
    }

    @Test func `should answer one attribute of an element from what the phone pushed`() throws {
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", records)))

        #expect(dump.answer(type: 2, attribute: 2001, element: button) == .value(attribute: 2001, "New Project" as NSString))
        #expect(dump.answer(type: 2, attribute: 2005, element: button) == .value(attribute: 2005, NSNumber(value: true)))
    }

    @Test func `should answer every attribute of an element at once`() throws {
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", records)))

        guard case let .values(values)? = dump.answer(type: 5, attribute: 0, element: button) else {
            Issue.record("no attributes"); return
        }
        #expect(values[NSNumber(value: 2002)] as? String == "AXButton")
        #expect(values.count == 3)
    }

    @Test func `should hand back the phone's own answers for the root, settability and global attributes`() throws {
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", records)))

        #expect(dump.answer(type: 4, attribute: 0, element: nil) == .response(records[0]))
        #expect(dump.answer(type: 3, attribute: 2001, element: button) == .response(records[3]))
        #expect(dump.answer(type: 2, attribute: 7, element: nil) == .response(records[4]))
    }

    @Test func `should have no answer for what the phone didn't push`() throws {
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", records)))
        let stranger = FakeAX(["pid": NSNumber(value: 812), "objectID": NSNumber(value: 99)])

        #expect(dump.answer(type: 2, attribute: 2001, element: stranger) == nil)
        #expect(dump.answer(type: 9, attribute: 0, element: button) == nil)
    }

    @Test func `should skip what the phone pushed that the translator never asks for`() throws {
        let unasked = FakeAX(["associatedRequestType": NSNumber(value: 11), "associatedTranslationObject": button])
        let dump = try #require(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", records + [unasked])))

        #expect(dump.answer(type: 11, attribute: 0, element: button) == nil)
        #expect(dump.answer(type: 2, attribute: 2001, element: button) == .value(attribute: 2001, "New Project" as NSString))
    }

    @Test func `should read no tree from a reply that isn't a tree dump`() {
        #expect(AXTreeDump(envelope: FakeAX(["resultData": NSDictionary()])) == nil)
        #expect(AXTreeDump(envelope: envelope("AXPTreeDumpTypeAdditionalData", [])) == nil)
    }
}
