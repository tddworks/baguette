import Testing
import Foundation
import Mockable
@testable import Baguette

/// Pure-value coverage for `RemoteNotification` — a notification a
/// developer wants delivered to one app on the simulator, as if APNs had
/// sent it.
///
/// Three laws live on the value: the payload must be one iOS would accept
/// (a top-level object carrying an `aps` object, 4096 bytes at most), it
/// must be addressed to an app, and it must say what the user will
/// actually see. That last one matters because delivery succeeding only
/// means the simulator took the notification — whether a banner appears
/// depends on what `aps` asks for, the app's authorisation and whether
/// it's in the foreground.
@Suite("RemoteNotification")
struct RemoteNotificationTests {

    private let order = Data(#"{"aps":{"alert":{"title":"Order update","body":"Tap to view your order"},"sound":"default"},"deep_link":"example://orders/123"}"#.utf8)

    private func notification(_ json: String, to app: String? = "com.example.app") throws -> RemoteNotification {
        try RemoteNotification.from(json: Data(json.utf8), addressedTo: app)
    }

    // MARK: - addressee

    @Test func `should address a notification to the app it names`() throws {
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        #expect(note.app == "com.example.app")
    }

    @Test func `should address a notification to the app its payload targets when no app is named`() throws {
        let note = try notification(#"{"aps":{"alert":"Hi"},"Simulator Target Bundle":"com.example.app"}"#, to: nil)
        #expect(note.app == "com.example.app")
    }

    @Test func `should address a notification to the named app when the payload targets another`() throws {
        let note = try notification(#"{"aps":{"alert":"Hi"},"Simulator Target Bundle":"com.other.app"}"#)
        #expect(note.app == "com.example.app")
    }

    @Test func `should refuse a notification addressed to no app`() {
        #expect(throws: RemoteNotificationError.noApp) {
            try RemoteNotification.from(json: order, addressedTo: nil)
        }
    }

    @Test func `should refuse a notification addressed to no app when the app name is blank`() {
        #expect(throws: RemoteNotificationError.noApp) {
            try RemoteNotification.from(json: order, addressedTo: "  ")
        }
    }

    // MARK: - payload

    @Test func `should keep app-defined payload fields exactly as written`() throws {
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        #expect(note.payload == order)
    }

    @Test func `should refuse a payload that isn't JSON`() {
        #expect(throws: RemoteNotificationError.notJSON) { try notification("{aps:") }
    }

    @Test func `should refuse a payload that isn't a JSON object`() {
        #expect(throws: RemoteNotificationError.notAnObject) { try notification(#"[{"aps":{}}]"#) }
    }

    @Test func `should refuse a payload with no aps entry`() {
        #expect(throws: RemoteNotificationError.missingAPS) { try notification(#"{"deep_link":"x://y"}"#) }
    }

    @Test func `should refuse a payload whose aps entry isn't an object`() {
        #expect(throws: RemoteNotificationError.missingAPS) { try notification(#"{"aps":"hello"}"#) }
    }

    @Test func `should accept a payload of exactly the APNs size limit`() {
        #expect(throws: Never.self) {
            try RemoteNotification.from(json: Self.payload(ofBytes: 4096), addressedTo: "com.example.app")
        }
    }

    @Test func `should refuse a payload over the APNs size limit`() {
        #expect(throws: RemoteNotificationError.tooLarge(bytes: 4097)) {
            try RemoteNotification.from(json: Self.payload(ofBytes: 4097), addressedTo: "com.example.app")
        }
    }

    // MARK: - presentation

    @Test func `should present an alert with the title and body the payload carries`() throws {
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        #expect(note.presentation.alert == .init(title: "Order update", subtitle: nil, body: "Tap to view your order"))
    }

    @Test func `should present an alert whose text is the whole alert when the alert is a plain string`() throws {
        let note = try notification(#"{"aps":{"alert":"Your order shipped"}}"#)
        #expect(note.presentation.alert == .init(title: nil, subtitle: nil, body: "Your order shipped"))
    }

    @Test func `should present an alert with its subtitle`() throws {
        let note = try notification(#"{"aps":{"alert":{"title":"T","subtitle":"S","body":"B"}}}"#)
        #expect(note.presentation.alert?.subtitle == "S")
    }

    @Test func `should present a badge count`() throws {
        let note = try notification(#"{"aps":{"badge":3}}"#)
        #expect(note.presentation.badge == 3)
        #expect(note.presentation.alert == nil)
    }

    @Test func `should present a sound`() throws {
        #expect(try notification(#"{"aps":{"sound":"default"}}"#).presentation.playsSound)
    }

    @Test func `should present no sound when the payload asks for none`() throws {
        #expect(try notification(#"{"aps":{"alert":"Hi"}}"#).presentation.playsSound == false)
    }

    @Test func `should present nothing for a background notification`() throws {
        let note = try notification(#"{"aps":{"content-available":1},"sync":"orders"}"#)
        #expect(note.presentation.isSilent)
        #expect(note.wakesInBackground)
    }

    @Test func `should not wake the app when a silent notification lacks content-available`() throws {
        let note = try notification(#"{"aps":{}}"#)
        #expect(note.presentation.isSilent)
        #expect(note.wakesInBackground == false)
    }

    @Test func `should not be silent when it shows an alert`() throws {
        #expect(try RemoteNotification.from(json: order, addressedTo: "com.example.app").presentation.isSilent == false)
    }

    // MARK: - expectation

    @Test func `should say a visible notification needs authorisation and a backgrounded app to show a banner`() throws {
        let expectation = try RemoteNotification.from(json: order, addressedTo: "com.example.app").expectation
        #expect(expectation.contains("accepted by the simulator"))
        #expect(expectation.contains("authorized"))
        #expect(expectation.contains("foreground"))
    }

    @Test func `should say a background notification shows nothing and wakes the app`() throws {
        let expectation = try notification(#"{"aps":{"content-available":1}}"#).expectation
        #expect(expectation.contains("shows nothing"))
        #expect(expectation.contains("wakes"))
    }

    @Test func `should say a silent notification without content-available does nothing visible or in the background`() throws {
        let expectation = try notification(#"{"aps":{}}"#).expectation
        #expect(expectation.contains("content-available"))
    }

    // MARK: - delivery

    @Test func `should hand simctl the device, the app and the payload file`() throws {
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        #expect(note.deliverArguments(udid: "U", payloadFile: URL(fileURLWithPath: "/tmp/n.json"))
            == ["simctl", "push", "U", "com.example.app", "/tmp/n.json"])
    }

    @Test func `should hand simctl the device's custom device set when it lives in one`() throws {
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        #expect(note.deliverArguments(
            udid: "U", deviceSetPath: "/custom set", payloadFile: URL(fileURLWithPath: "/tmp/n.json"))
            == ["simctl", "--set", "/custom set", "push", "U", "com.example.app", "/tmp/n.json"])
    }

    @Test func `should be delivered by the device's notifications`() async throws {
        let notify = MockNotify()
        given(notify).deliver(.any).willReturn()
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        try await note.deliver(to: notify)
        verify(notify).deliver(.value(note)).called(1)
    }

    // MARK: - report

    @Test func `should report a delivered notification with its app, what it shows and what to expect`() throws {
        let note = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        let report = try #require(
            JSONSerialization.jsonObject(with: Data(note.deliveredJSON.utf8)) as? [String: Any]
        )
        #expect(report["ok"] as? Bool == true)
        #expect(report["app"] as? String == "com.example.app")
        #expect(report["expectation"] as? String == note.expectation)
        let presentation = try #require(report["presentation"] as? [String: Any])
        #expect(presentation["silent"] as? Bool == false)
        #expect(presentation["sound"] as? Bool == true)
        #expect(presentation["alert"] as? [String: String] == ["title": "Order update", "body": "Tap to view your order"])
    }

    @Test func `should report a background notification as silent and waking the app`() throws {
        let note = try notification(#"{"aps":{"content-available":1,"badge":0}}"#)
        let report = try #require(
            JSONSerialization.jsonObject(with: Data(note.deliveredJSON.utf8)) as? [String: Any]
        )
        let presentation = try #require(report["presentation"] as? [String: Any])
        #expect(presentation["badge"] as? Int == 0)
        #expect(presentation["wakesInBackground"] as? Bool == true)
        #expect(presentation["alert"] == nil)
    }

    // MARK: - refusals

    @Test func `should explain each refusal in one sentence a developer can act on`() {
        #expect(RemoteNotificationError.notJSON.description == "payload is not valid JSON")
        #expect(RemoteNotificationError.notAnObject.description == "payload must be a JSON object at the top level")
        #expect(RemoteNotificationError.missingAPS.description == #"payload needs an "aps" object, e.g. {"aps":{"alert":"Hi"}}"#)
        #expect(RemoteNotificationError.tooLarge(bytes: 5000).description == "payload is 5000 bytes; APNs allows at most 4096")
        #expect(RemoteNotificationError.noApp.description == #"no app to notify: pass a bundle id, or add "Simulator Target Bundle" to the payload"#)
    }

    /// A valid payload padded to exactly `bytes` long.
    private static func payload(ofBytes bytes: Int) -> Data {
        let shell = #"{"aps":{},"pad":""}"#
        let pad = String(repeating: "x", count: bytes - shell.utf8.count)
        return Data(#"{"aps":{},"pad":"\#(pad)"}"#.utf8)
    }
}
