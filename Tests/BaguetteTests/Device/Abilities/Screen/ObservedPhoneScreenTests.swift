import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("ConnectedScreens.observedPhone")
struct ObservedPhoneScreenTests {
    static let cover = ConnectedScreenRecord(
        screenId: 1, name: "Cover", screenType: .integrated,
        size: Size(width: 1206, height: 2622), deviceName: "primary", scale: 3)
    static let inner = ConnectedScreenRecord(
        screenId: 2, name: "Inner", screenType: .integrated,
        size: Size(width: 2200, height: 2800), deviceName: "primary-1", scale: 2)
    static let ports = [
        SizedFramebuffer(portName: "cover", size: cover.size),
        SizedFramebuffer(portName: "inner", size: inner.size),
    ]

    @Test func `should observe a single integrated screen without a hinge sample or a panel name`() throws {
        let anonymous = ConnectedScreenRecord(
            screenId: 1, name: "LCD", screenType: .integrated, size: Self.cover.size, scale: 3)
        let observed = try ConnectedScreens.observedPhone(ports: [Self.ports[0]], screens: [anonymous], angle: nil)
        #expect(observed.binding.connectedScreenId == 1)
        #expect(observed.binding.panel == nil)
        #expect(observed.multiplePanels == false)
        #expect(observed.binding.pointSize(scale: observed.scale) == Size(width: 402, height: 874))
    }

    @Test func `should observe the panel the hinge lights when a device has two`() throws {
        let opened = try ConnectedScreens.observedPhone(
            ports: Self.ports, screens: [Self.cover, Self.inner], angle: HingeAngle(degrees: 180))
        #expect(opened.binding.connectedScreenId == 2)
        #expect(opened.binding.panel == .secondary)
        #expect(opened.multiplePanels)
        #expect(opened.binding.pointSize(scale: opened.scale) == Size(width: 1100, height: 1400))

        let closed = try ConnectedScreens.observedPhone(
            ports: Self.ports, screens: [Self.cover, Self.inner], angle: HingeAngle(degrees: 3))
        #expect(closed.binding.connectedScreenId == 1)
        #expect(closed.binding.panel == .primary)
    }

    @Test func `should report the screen unavailable instead of guessing the cover when two panels have no hinge sample`() {
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(ports: Self.ports, screens: [Self.cover, Self.inner], angle: nil)
        }
    }

    @Test func `should report the screen unavailable unless exactly one framebuffer matches the lit panel's size`() {
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(
                ports: [Self.ports[0]], screens: [Self.cover, Self.inner], angle: HingeAngle(degrees: 180))
        }
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(
                ports: Self.ports + [Self.ports[1]], screens: [Self.cover, Self.inner], angle: HingeAngle(degrees: 180))
        }
    }

    @Test func `should report the screen unavailable when it has no usable scale for point geometry`() {
        let unscaled = ConnectedScreenRecord(
            screenId: 1, name: "LCD", screenType: .integrated, size: Self.cover.size)
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(ports: [Self.ports[0]], screens: [unscaled], angle: nil)
        }
    }
}
