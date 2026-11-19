import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `simctl io enumerate` Connected Screens is the live topology:
/// creatable CarPlay (101) is ignored until a TVOut/CarPlay screen
/// appears under Connected Screens.
@Suite("SimctlIOEnumerate")
struct SimctlIOEnumerateTests {

    private let connectedSample = """
        Creatable Screen Properties:
        (101) CarPlay:
            Screen ID: 101
            Name: CarPlay
            Screen Type: CarPlay
            Pixel Size: {720, 480}
        Connected Screens:
        (1) LCD:
            Screen ID: 1
            Name: LCD
            Unique ID: PurpleMain
            Device Name: primary
            Screen Type: Integrated
            Pixel Size: {1206, 2622}
        (2) TVOut:
            Screen ID: 2
            Name: TVOut
            Unique ID: PurpleTVOut
            Device Name: external-0
            Screen Type: TVOut
            Pixel Size: {720, 480}
        """

    /// iPhone Duo on iOS 27.1: two Integrated screens. The cover panel
    /// is `primary`; the larger unfolded panel is `primary-1`.
    private let foldableSample = """
        Connected Screens:
        (1) LCD:
            Screen ID: 1
            Name: LCD
            Unique ID: 12181DAB-A25B-43FE-B650-F5F8F0662C48
            Device Name: primary
            Screen Type: Integrated
            Pixel Size: {1398, 2034}
            UI Orientation: Portrait
        (3) LCD-1:
            Screen ID: 3
            Name: LCD-1
            Unique ID: A68E892B-8EC1-4ECA-8A1B-88D080EAFFCD
            Device Name: primary-1
            Screen Type: Integrated
            Pixel Size: {2007, 2853}
            UI Orientation: Landscape Left
        """

    private let phoneOnlySample = """
        Creatable Screen Properties:
        (101) CarPlay:
            Screen ID: 101
            Screen Type: CarPlay
            Pixel Size: {720, 480}
        Connected Screens:
        (1) LCD:
            Screen ID: 1
            Screen Type: Integrated
            Pixel Size: {1206, 2622}
        """

    @Test func `should see CarPlay connected when Connected Screens lists a TVOut`() {
        #expect(SimctlIOEnumerate.isCarPlayConnected(connectedSample))
    }

    @Test func `should not see CarPlay connected when it is only creatable`() {
        #expect(!SimctlIOEnumerate.isCarPlayConnected(phoneOnlySample))
    }

    @Test func `should read each connected screen's live id, type and size`() {
        let screens = SimctlIOEnumerate.connectedScreens(from: connectedSample)
        #expect(screens.count == 2)
        #expect(screens[0].screenId == 1)
        #expect(screens[0].screenType == .integrated)
        #expect(screens[0].size == Size(width: 1206, height: 2622))
        #expect(screens[1].screenId == 2)
        #expect(screens[1].screenType == .tvOut)
        #expect(screens[1].size == Size(width: 720, height: 480))
    }

    @Test func `should find the connected TVOut as CarPlay, not the creatable 101`() {
        let carPlay = SimctlIOEnumerate.connectedCarPlay(from: connectedSample)
        #expect(carPlay?.screenId == 2)
        #expect(carPlay?.screenType == .tvOut)
    }

    @Test func `should find no CarPlay screen when only the phone is connected`() {
        #expect(SimctlIOEnumerate.connectedCarPlay(from: phoneOnlySample) == nil)
    }

    // MARK: - orientation

    /// The guest reports each screen's interface orientation. iPhone
    /// Duo's open pose puts SpringBoard in landscape by itself, so this
    /// is how the page learns which way to turn a panel it did not
    /// rotate. Names are the guest's; the mapping to baguette's device
    /// orientations was measured on the framebuffer — "Landscape Left"
    /// content reads upright after the page's `landscape-left` turn.
    @Test func `should read each screen's UI orientation`() {
        let screens = SimctlIOEnumerate.connectedScreens(from: foldableSample)
        #expect(screens[0].uiOrientation == .portrait)
        #expect(screens[1].uiOrientation == .landscapeLeft)
    }

    @Test func `should leave the orientation unknown when it is ambiguous or missing`() {
        let ambiguous = """
            Connected Screens:
            (2) TVOut:
                Screen ID: 2
                Screen Type: TVOut
                Pixel Size: {720, 480}
                UI Orientation: Ambiguous
            """
        #expect(SimctlIOEnumerate.connectedScreens(from: ambiguous)[0].uiOrientation == nil)
        #expect(SimctlIOEnumerate.connectedScreens(from: phoneOnlySample)[0].uiOrientation == nil)
    }

    @Test func `should read each screen's preferred UI scale when the runtime reports one`() {
        let scaled = """
            Connected Screens:
            (1) Integrated:
                Screen ID: 1
                Screen Type: Integrated
                Pixel Size: {1206, 2622}
                Device Name: primary
                UI Orientation: Portrait
                Preferred UI Scale: 3.0
            """
        #expect(SimctlIOEnumerate.connectedScreens(from: scaled)[0].scale == 3)
        #expect(SimctlIOEnumerate.connectedScreens(from: phoneOnlySample)[0].scale == nil)
    }

    @Test func `should understand the guest's orientation names`() {
        #expect(SimctlIOEnumerate.orientation(named: "Portrait") == .portrait)
        #expect(SimctlIOEnumerate.orientation(named: "Portrait Upside Down") == .portraitUpsideDown)
        #expect(SimctlIOEnumerate.orientation(named: "Landscape Left") == .landscapeLeft)
        #expect(SimctlIOEnumerate.orientation(named: "Landscape Right") == .landscapeRight)
        #expect(SimctlIOEnumerate.orientation(named: "Ambiguous") == nil)
    }

    // MARK: - panels

    @Test func `should read the device name of each connected screen`() {
        let screens = SimctlIOEnumerate.connectedScreens(from: connectedSample)
        #expect(screens[0].deviceName == "primary")
        #expect(screens[1].deviceName == "external-0")
    }

    /// A foldable lists two Integrated screens: CoreSimulator names the
    /// cover `primary` and the unfolded panel `primary-1`. Which one is
    /// lit is the hinge's business, not the name's.
    @Test func `should know a foldable's integrated screens as its primary and secondary panels`() {
        let screens = SimctlIOEnumerate.connectedScreens(from: foldableSample)
        #expect(screens.count == 2)
        #expect(screens[0].panel == .primary)
        #expect(screens[1].panel == .secondary)
        #expect(screens[1].screenType == .integrated)
    }

    /// An external is never a panel, whatever it is called.
    @Test func `should not treat an external screen as a panel`() {
        let screens = SimctlIOEnumerate.connectedScreens(from: connectedSample)
        #expect(screens[1].panel == nil)
    }

    /// Older enumerate output without a Device Name line still parses;
    /// it just cannot name a panel, so callers fall back to shape.
    @Test func `should not treat a screen without a device name as a named panel`() {
        let screens = SimctlIOEnumerate.connectedScreens(from: phoneOnlySample)
        #expect(screens[0].deviceName == "")
        #expect(screens[0].panel == nil)
    }
}
