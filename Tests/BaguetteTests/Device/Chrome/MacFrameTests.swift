import Testing
@testable import BaguetteDevice

/// A Mac's frame a display can be shown in: a picture of the Mac, its screen
/// at the opening measured in the picture.
@Suite("MacFrame")
struct MacFrameTests {
    let iMac27 = MacFrame(name: "iMac 27-inch", image: Size(width: 5640, height: 4540),
                          screen: Rect(origin: Point(x: 260, y: 250), size: Size(width: 5120, height: 2880)))

    @Test func `should frame the screen at its measured opening`() {
        #expect(iMac27.chrome.screenInsets == Insets(top: 250, left: 260, bottom: 1410, right: 260))
        #expect(iMac27.chrome.screenRect(in: iMac27.image) == iMac27.screen)
    }

    @Test func `should frame the screen square and without buttons`() {
        #expect(iMac27.chrome.identifier == "iMac 27-inch")
        #expect(iMac27.chrome.outerCornerRadius == 0)
        #expect(iMac27.chrome.buttons.isEmpty)
    }

    @Test func `should fit a display of the same shape as its screen`() {
        #expect(iMac27.fits(Size(width: 2560, height: 1440)))
        #expect(iMac27.fits(Size(width: 1280, height: 722)))   // within 2%
    }

    @Test func `should not fit a display of another shape`() {
        #expect(!iMac27.fits(Size(width: 1440, height: 2560)))  // portrait
        #expect(!iMac27.fits(Size(width: 1512, height: 982)))   // a MacBook's 16:10
        #expect(!iMac27.fits(Size(width: 0, height: 0)))
    }

    @Test func `should know every frame measured, each once`() {
        let names = MacFrame.measured.map(\.name)
        #expect(names.count == 9)
        #expect(Set(names).count == names.count)
        #expect(names.contains("MacBook Pro 14-inch (M4)"))
        #expect(names.contains("iMac 27-inch"))
    }

    @Test func `should offer the frames a display fits, in the order measured`() {
        #expect(MacFrame.fitting(Size(width: 2560, height: 1440)).map(\.name) == ["iMac 24-inch", "iMac 27-inch"])
        #expect(MacFrame.fitting(Size(width: 1440, height: 2560)).isEmpty)
        #expect(MacFrame.fitting(Size(width: 1512, height: 982)).map(\.name).contains("MacBook Pro 14-inch (M4)"))
    }
}
