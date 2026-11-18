import Foundation
import HTTPTypes
import Testing
@testable import Baguette

@Suite("Server device routes")
struct DeviceRoutesTests {
    @Test func `should answer a device id nobody knows as not found`() {
        #expect(Server.status(for: DeviceError.unknown(id: "NOPE")) == .notFound)
    }

    @Test func `should answer an ability the device lacks as unprocessable`() {
        #expect(Server.status(for: DeviceError.unable(ability: "screen", device: "han's iPhone")) == .unprocessableContent)
    }

    @Test func `should answer a device that isn't ready, or is claimed twice, as a conflict`() {
        #expect(Server.status(for: DeviceError.notReady(device: "iPhone 17", state: .off)) == .conflict)
        #expect(Server.status(for: DeviceError.claimedTwice(id: "SAME")) == .conflict)
    }

    @Test func `should answer any other failure as a server error`() {
        struct Broken: Error {}
        #expect(Server.status(for: Broken()) == .internalServerError)
    }
}
