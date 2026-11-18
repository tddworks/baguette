import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for `POST /simulators/:udid/notify`, driven
/// through the pure `Server.notify` helper with one device's
/// `MockApps` rather than Hummingbird.
///
/// The payload is judged before the device is looked up: a payload with
/// no `aps` is wrong on every device, and saying so beats blaming a udid
/// that may be fine.
@Suite("Server notify route")
struct NotifyRoutesTests {

    private let order = Data(#"{"aps":{"alert":"Your order shipped"},"deep_link":"example://orders/123"}"#.utf8)

    private func host(deliverError: AppsError? = nil) -> (any Devices, MockNotify) {
        let apps = MockNotify()
        let simulators = routeDevices { $0.register(.notify) { apps } }
        if let deliverError {
            given(apps).deliver(.any).willThrow(deliverError)
        } else {
            given(apps).deliver(.any).willReturn()
        }
        return (simulators, apps)
    }

    @Test func `should deliver a notification to the app named in the request`() async throws {
        let (simulators, apps) = host()
        let outcome = await Server.notify(udid: "U", app: "com.example.app", payload: order, devices: simulators)

        let expected = try RemoteNotification.from(json: order, addressedTo: "com.example.app")
        #expect(outcome == .delivered(expected))
        verify(apps).deliver(.value(expected)).called(1)
    }

    @Test func `should refuse a malformed payload before looking for the device`() async {
        let (simulators, apps) = host()
        let outcome = await Server.notify(
            udid: "nope", app: "com.example.app", payload: Data(#"{"deep_link":"x://y"}"#.utf8), devices: simulators
        )
        #expect(outcome == .badPayload(.missingAPS))
        verify(apps).deliver(.any).called(0)
    }

    @Test func `should refuse a notification addressed to no app`() async {
        let (simulators, _) = host()
        let outcome = await Server.notify(udid: "U", app: nil, payload: order, devices: simulators)
        #expect(outcome == .badPayload(.noApp))
    }

    @Test func `should report an unknown device`() async {
        let (simulators, _) = host()
        let outcome = await Server.notify(udid: "nope", app: "com.example.app", payload: order, devices: simulators)
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report an unknown device when no device is named`() async {
        let (simulators, _) = host()
        let outcome = await Server.notify(udid: "", app: "com.example.app", payload: order, devices: simulators)
        #expect(outcome == .unknownDevice)
    }

    @Test func `should report that the app isn't allowed notifications`() async {
        let (simulators, _) = host(deliverError: .notificationsNotAllowed(app: "com.example.app"))
        let outcome = await Server.notify(udid: "U", app: "com.example.app", payload: order, devices: simulators)
        #expect(outcome == .notAllowed(AppsError.notificationsNotAllowed(app: "com.example.app").description))
    }

    @Test func `should report a refused delivery in simctl's own words`() async {
        let (simulators, _) = host(deliverError: .deliverFailed(status: 22, message: "Unable to lookup app"))
        let outcome = await Server.notify(udid: "U", app: "com.example.app", payload: order, devices: simulators)
        #expect(outcome == .deliverFailed("xcrun simctl push exited 22: Unable to lookup app"))
    }

    @Test func `should refuse a notification for a device that can't be sent one, naming it`() async {
        let outcome = await Server.notify(
            udid: "U", app: "com.x", payload: Data(#"{"aps":{"alert":"hi"}}"#.utf8),
            devices: routeDevices(name: "han's iPhone"))

        #expect(outcome == .refused(.unable(ability: "notify", device: "han's iPhone")))
    }

    @Test func `should answer notify under the devices tree and a simulator's old one`() {
        #expect(Server.deviceRoutes("notify") == ["/devices/:udid/notify", "/simulators/:udid/notify"])
    }
}
