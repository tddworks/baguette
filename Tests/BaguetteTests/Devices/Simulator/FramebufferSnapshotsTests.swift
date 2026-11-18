import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Live IOSurface sizes join to Connected Screens by closest pixel size
/// so Creatable CarPlay 101 never stamps a phone or external port.
@Suite("FramebufferSnapshots")
struct FramebufferSnapshotsTests {

    @Test func `should match each framebuffer to the connected screen closest in pixel size`() {
        let ports = [
            SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: Size(width: 1206, height: 2622)
            ),
            SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: Size(width: 800, height: 480)
            ),
        ]
        let screens = [
            ConnectedScreenRecord(
                screenId: 1,
                name: "LCD",
                screenType: .integrated,
                size: Size(width: 1206, height: 2622)
            ),
            ConnectedScreenRecord(
                screenId: 2,
                name: "TVOut",
                screenType: .tvOut,
                size: Size(width: 720, height: 480)
            ),
        ]

        let snapshots = FramebufferSnapshots.assigningScreenIds(
            ports: ports,
            screens: screens
        )

        #expect(snapshots.count == 2)
        #expect(snapshots[0].connectedScreenId == 1)
        #expect(snapshots[0].size == Size(width: 1206, height: 2622))
        #expect(snapshots[1].connectedScreenId == 2)
        #expect(snapshots[1].size == Size(width: 800, height: 480))
    }

    /// The port itself has no idea which panel it is; the name comes
    /// from the Connected Screens record it joins to.
    @Test func `should give a framebuffer the panel and orientation of its matched screen`() {
        let ports = [
            SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: Size(width: 2007, height: 2853)
            ),
            SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: Size(width: 1398, height: 2034)
            ),
        ]
        let screens = [
            ConnectedScreenRecord(
                screenId: 1, name: "LCD", screenType: .integrated,
                size: Size(width: 1398, height: 2034), deviceName: "primary"
            ),
            ConnectedScreenRecord(
                screenId: 3, name: "LCD-1", screenType: .integrated,
                size: Size(width: 2007, height: 2853), deviceName: "primary-1",
                uiOrientation: .landscapeLeft
            ),
        ]

        let snapshots = FramebufferSnapshots.assigningScreenIds(
            ports: ports, screens: screens
        )

        #expect(snapshots[0].connectedScreenId == 3)
        #expect(snapshots[0].panel == .secondary)
        #expect(snapshots[0].orientation == .landscapeLeft)
        #expect(snapshots[1].orientation == nil)
        #expect(snapshots[1].connectedScreenId == 1)
        #expect(snapshots[1].panel == .primary)
    }

    @Test func `should name no panel for a framebuffer with no matched screen`() {
        let snapshots = FramebufferSnapshots.assigningScreenIds(
            ports: [SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: Size(width: 100, height: 100)
            )],
            screens: []
        )
        #expect(snapshots[0].panel == nil)
    }

    @Test func `should leave the screen id unset when no connected screen remains to match`() {
        let ports = [
            SizedFramebuffer(
                portName: "com.apple.framebuffer.display",
                size: Size(width: 100, height: 100)
            ),
        ]
        let snapshots = FramebufferSnapshots.assigningScreenIds(
            ports: ports,
            screens: []
        )
        #expect(snapshots[0].connectedScreenId == nil)
    }

    @Test func `should bind phone and CarPlay to the live screen ids just matched`() throws {
        let ports = FramebufferSnapshots.assigningScreenIds(
            ports: [
                SizedFramebuffer(
                    portName: "com.apple.framebuffer.display",
                    size: Size(width: 1179, height: 2556)
                ),
                SizedFramebuffer(
                    portName: "com.apple.framebuffer.display",
                    size: Size(width: 800, height: 480)
                ),
            ],
            screens: [
                ConnectedScreenRecord(
                    screenId: 1,
                    name: "LCD",
                    screenType: .integrated,
                    size: Size(width: 1179, height: 2556)
                ),
                ConnectedScreenRecord(
                    screenId: 204,
                    name: "TVOut",
                    screenType: .tvOut,
                    size: Size(width: 720, height: 480)
                ),
            ]
        )

        let phone = try ConnectedScreens.binding(kind: .phone, ports: ports)
        let carPlay = try ConnectedScreens.binding(kind: .carPlay, ports: ports)

        #expect(phone.connectedScreenId == 1)
        #expect(carPlay.connectedScreenId == 204)
        #expect(carPlay.connectedScreenId != 101)
    }
}
