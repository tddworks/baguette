import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Port selection over live framebuffer snapshots: phone is the largest
/// plane; CarPlay is the best remaining external after that winner is
/// excluded, and refuses to bind without a connected screen id.
@Suite("ConnectedScreens")
struct ConnectedScreensTests {

    private let phoneFramebuffer = FramebufferSnapshot(
        portName: "com.apple.framebuffer.display",
        connectedScreenId: 1,
        size: Size(width: 1179, height: 2556)
    )
    private let carPlayFramebuffer = FramebufferSnapshot(
        portName: "com.apple.framebuffer.display",
        connectedScreenId: 204,
        size: Size(width: 800, height: 480)
    )
    private let overlayFramebuffer = FramebufferSnapshot(
        portName: "com.apple.framebuffer.display",
        connectedScreenId: 2,
        size: Size(width: 100, height: 100)
    )

    // MARK: - foldable

    /// iPhone Duo (iOS 27.1): the cover (`primary`, 1398×2034) and the
    /// unfolded panel (`primary-1`, 2007×2853). Both are portrait and
    /// both are Integrated, so shape cannot pick; the hinge says which
    /// one the guest lights, and the phone plane binds that one.
    private let coverPanel = FramebufferSnapshot(
        portName: "com.apple.framebuffer.display",
        connectedScreenId: 1,
        size: Size(width: 1398, height: 2034),
        panel: .primary
    )
    private let unfoldedPanel = FramebufferSnapshot(
        portName: "com.apple.framebuffer.display",
        connectedScreenId: 3,
        size: Size(width: 2007, height: 2853),
        panel: .secondary,
        orientation: .landscapeLeft
    )

    @Test func `should bind the phone to the cover panel, not the larger dark one, when folded`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [unfoldedPanel, coverPanel],
            litPanel: .primary
        )
        #expect(binding.connectedScreenId == 1)
        #expect(binding.size == coverPanel.size)
    }

    @Test func `should bind the phone to the unfolded panel when unfolded`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [unfoldedPanel, coverPanel],
            litPanel: .secondary
        )
        #expect(binding.connectedScreenId == 3)
        #expect(binding.size == unfoldedPanel.size)
        // The guest turned the unfolded panel; the binding says so.
        #expect(binding.orientation == .landscapeLeft)
    }

    /// With no hinge reading the device is taken as it boots: folded.
    @Test func `should bind the phone to the cover panel when there is no hinge reading`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [unfoldedPanel, coverPanel]
        )
        #expect(binding.connectedScreenId == 1)
    }

    /// A single-panel device has only a primary; asking for the
    /// secondary must not bind nothing.
    @Test func `should bind a device's only panel whatever the hinge says`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [coverPanel, carPlayFramebuffer],
            litPanel: .secondary
        )
        #expect(binding.connectedScreenId == 1)
    }

    /// The second panel is portrait, so it is never mistaken for an
    /// external either.
    @Test func `should not bind a foldable's second panel as CarPlay`() {
        #expect(throws: FramebufferSelectionError.noMatchingFramebuffer(.carPlay)) {
            try ConnectedScreens.binding(
                kind: .carPlay,
                ports: [unfoldedPanel, coverPanel]
            )
        }
    }

    /// Without a named panel — every device before the Duo, and older
    /// enumerate output — shape still decides, exactly as before.
    @Test func `should still bind the phone to the largest portrait screen when no panel is named`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [overlayFramebuffer, phoneFramebuffer, carPlayFramebuffer]
        )
        #expect(binding.connectedScreenId == 1)
    }

    @Test func `should bind the phone to the largest-area screen with its id, port and size`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [overlayFramebuffer, phoneFramebuffer, carPlayFramebuffer]
        )
        #expect(binding.kind == .phone)
        #expect(binding.connectedScreenId == 1)
        #expect(binding.portName == phoneFramebuffer.portName)
        #expect(binding.size == phoneFramebuffer.size)
    }

    @Test func `should bind CarPlay to the best external screen, never the phone's`() throws {
        let binding = try ConnectedScreens.binding(
            kind: .carPlay,
            ports: [phoneFramebuffer, carPlayFramebuffer, overlayFramebuffer]
        )
        #expect(binding.kind == .carPlay)
        #expect(binding.connectedScreenId == 204)
        #expect(binding.size == carPlayFramebuffer.size)
    }

    @Test func `should bind CarPlay to the larger runtime screen over the 720x480 plist size when areas differ`() throws {
        let plistSized = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 101,
            size: Size(width: 720, height: 480)
        )
        let runtimeLarger = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 204,
            size: Size(width: 800, height: 480)
        )
        let binding = try ConnectedScreens.binding(
            kind: .carPlay,
            ports: [phoneFramebuffer, plistSized, runtimeLarger]
        )
        #expect(binding.connectedScreenId == 204)
        #expect(binding.size == runtimeLarger.size)
    }

    @Test func `should bind CarPlay to the screen nearest 720x480 only when areas tie`() throws {
        let nearPlist = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 101,
            size: Size(width: 720, height: 480)
        )
        let sameAreaFarther = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 205,
            size: Size(width: 960, height: 360) // same 345600 area, farther from 720×480
        )
        let binding = try ConnectedScreens.binding(
            kind: .carPlay,
            ports: [phoneFramebuffer, sameAreaFarther, nearPlist]
        )
        #expect(binding.connectedScreenId == 101)
        #expect(binding.size == nearPlist.size)
    }

    /// A 4K external out-measures every phone, so "the device is the
    /// largest plane" quietly hands the device slot to the external —
    /// and the portrait phone left over is not a landscape external, so
    /// the pane then reported nothing attached for a screen the user was
    /// looking at. The device is picked by its own shape, not by size.
    @Test func `should bind CarPlay to a 4K external screen larger than the phone`() throws {
        let uhd = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 2,
            size: Size(width: 3840, height: 2160)
        )
        let binding = try ConnectedScreens.binding(
            kind: .carPlay,
            ports: [phoneFramebuffer, uhd]
        )
        #expect(binding.connectedScreenId == 2)
        #expect(binding.size == uhd.size)
    }

    /// Same list, other plane: the phone must not be handed the external
    /// either, or the device pane streams the car's screen.
    @Test func `should keep the phone on its own screen when a larger external one is attached`() throws {
        let uhd = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 2,
            size: Size(width: 3840, height: 2160)
        )
        let binding = try ConnectedScreens.binding(
            kind: .phone,
            ports: [uhd, phoneFramebuffer]
        )
        #expect(binding.connectedScreenId == 1)
        #expect(binding.size == phoneFramebuffer.size)
    }

    @Test func `should find no CarPlay screen when only the phone is connected`() {
        #expect(throws: FramebufferSelectionError.noMatchingFramebuffer(.carPlay)) {
            try ConnectedScreens.binding(kind: .carPlay, ports: [phoneFramebuffer])
        }
    }

    @Test func `should refuse a second phone-sized screen as CarPlay`() {
        let phoneMirror = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: 3,
            size: Size(width: 1170, height: 2532)
        )
        #expect(throws: FramebufferSelectionError.noMatchingFramebuffer(.carPlay)) {
            try ConnectedScreens.binding(
                kind: .carPlay,
                ports: [phoneFramebuffer, phoneMirror]
            )
        }
    }

    @Test func `should report no screen id when the CarPlay screen is not connected`() {
        let disconnected = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: nil,
            size: Size(width: 800, height: 480)
        )
        #expect(throws: FramebufferSelectionError.screenIdUnavailable) {
            try ConnectedScreens.binding(
                kind: .carPlay,
                ports: [phoneFramebuffer, disconnected]
            )
        }
    }

    @Test func `should find no phone screen when no screens are connected`() {
        #expect(throws: FramebufferSelectionError.noMatchingFramebuffer(.phone)) {
            try ConnectedScreens.binding(kind: .phone, ports: [])
        }
    }

    @Test func `should report no screen id when the phone screen is not connected`() {
        let headless = FramebufferSnapshot(
            portName: "com.apple.framebuffer.display",
            connectedScreenId: nil,
            size: Size(width: 1179, height: 2556)
        )
        #expect(throws: FramebufferSelectionError.screenIdUnavailable) {
            try ConnectedScreens.binding(kind: .phone, ports: [headless])
        }
    }
}

/// The bound panel's size in points — what accessibility frames are
/// expressed in. On a foldable the lit panel changes with the hinge,
/// so the AX space has to come from the binding, not from the device
/// type's single `mainScreenSize`.
@Suite("DisplayBinding point size")
struct DisplayBindingPointSizeTests {

    @Test func `should size a screen in points as its pixels over the scale`() {
        let unfolded = DisplayBinding(
            kind: .phone, connectedScreenId: 3,
            portName: "com.apple.framebuffer.display",
            size: Size(width: 2007, height: 2853)
        )
        #expect(unfolded.pointSize(scale: 3) == Size(width: 669, height: 951))
    }

    @Test func `should give no point size when the scale is zero or negative`() {
        let cover = DisplayBinding(
            kind: .phone, connectedScreenId: 1,
            portName: "com.apple.framebuffer.display",
            size: Size(width: 1398, height: 2034)
        )
        #expect(cover.pointSize(scale: 0) == nil)
        #expect(cover.pointSize(scale: -1) == nil)
    }
}
