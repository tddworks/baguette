import Foundation
import Testing

@testable import Baguette

@Suite("ConnectedScreens.observedPhone")
struct ObservedPhoneScreenTests {
    static let cover = ConnectedScreenRecord(
        screenId: 1, name: "Cover", screenType: .integrated,
        size: Size(width: 1206, height: 2622), deviceName: "primary", scale: 3)
    static let inner = ConnectedScreenRecord(
        screenId: 2, name: "Inner", screenType: .integrated,
        size: Size(width: 2200, height: 2800), deviceName: "primary-1", scale: 2)
    static let ports = [
        SizedFramebufferPort(portName: "cover", size: cover.size),
        SizedFramebufferPort(portName: "inner", size: inner.size),
    ]

    @Test func `a single integrated screen binds without a hinge sample or a panel name`() throws {
        let anonymous = ConnectedScreenRecord(
            screenId: 1, name: "LCD", screenType: .integrated, size: Self.cover.size, scale: 3)
        let observed = try ConnectedScreens.observedPhone(ports: [Self.ports[0]], screens: [anonymous], angle: nil)
        #expect(observed.binding.connectedScreenId == 1)
        #expect(observed.binding.panel == nil)
        #expect(observed.multiplePanels == false)
        #expect(observed.binding.pointSize(scale: observed.scale) == Size(width: 402, height: 874))
    }

    @Test func `two panels bind the one the hinge lights`() throws {
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

    @Test func `two panels without a fresh hinge sample fail instead of guessing the cover`() {
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(ports: Self.ports, screens: [Self.cover, Self.inner], angle: nil)
        }
    }

    @Test func `the lit panel needs exactly one framebuffer of its size`() {
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(
                ports: [Self.ports[0]], screens: [Self.cover, Self.inner], angle: HingeAngle(degrees: 180))
        }
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(
                ports: Self.ports + [Self.ports[1]], screens: [Self.cover, Self.inner], angle: HingeAngle(degrees: 180))
        }
    }

    @Test func `a screen without a usable scale cannot provide point geometry`() {
        let unscaled = ConnectedScreenRecord(
            screenId: 1, name: "LCD", screenType: .integrated, size: Self.cover.size)
        #expect(throws: ObservedScreenError.unavailable) {
            try ConnectedScreens.observedPhone(ports: [Self.ports[0]], screens: [unscaled], angle: nil)
        }
    }
}
