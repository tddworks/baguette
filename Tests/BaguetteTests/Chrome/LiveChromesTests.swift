import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("LiveChromes")
struct LiveChromesTests {

    // MARK: - happy path

    @Test func `assets returns parsed chrome and rasterized composite`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let pdf = Data("PDF-COMPOSITE".utf8)
        let png = ChromeImage(data: Data("PNG-DATA".utf8), size: Size(width: 393, height: 852))

        given(store).profilePlistData(deviceName: .value("iPhone 17 Pro"))
            .willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .value("phone11"))
            .willReturn(Self.fixtureChromeJSON)
        given(store).chromeAssetPDF(chromeIdentifier: .value("phone11"), imageName: .value("PhoneComposite"))
            .willReturn(pdf)
        given(rasterizer).rasterize(pdfData: .value(pdf)).willReturn(png)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        let assets = chromes.assets(forDeviceName: "iPhone 17 Pro")

        #expect(assets?.chrome.identifier == "phone11")
        #expect(assets?.composite == png)
    }

    @Test func `assets caches by chrome identifier across repeated lookups`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let pdf = Data("X".utf8)
        let png = ChromeImage(data: Data("Y".utf8), size: Size(width: 1, height: 1))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any).willReturn(Self.fixtureChromeJSON)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .any).willReturn(pdf)
        given(rasterizer).rasterize(pdfData: .any).willReturn(png)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        _ = chromes.assets(forDeviceName: "iPhone 17 Pro")
        _ = chromes.assets(forDeviceName: "iPhone 17 Pro")
        _ = chromes.assets(forDeviceName: "iPhone 17 Pro")

        // The expensive work — JSON parse + PDF read + rasterize — runs once.
        verify(store).chromeJSONData(chromeIdentifier: .any).called(1)
        verify(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .any).called(1)
        verify(rasterizer).rasterize(pdfData: .any).called(1)
        // The plist resolves the identifier, so it's read for every call.
        verify(store).profilePlistData(deviceName: .any).called(3)
    }

    // MARK: - degraded paths — every step gives nil cleanly

    @Test func `assets returns nil when profile plist is unreadable`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willThrow(StubError.notFound)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    @Test func `assets returns nil when chrome JSON is unreadable`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any).willThrow(StubError.notFound)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    @Test func `assets returns nil when chrome relies on 9-slice (no composite)`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONNoComposite)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        // No composite image → we don't rasterize, return nil. Caller can
        // fall back to a plain stream.
        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    @Test func `assets returns nil when composite PDF is unreadable`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any).willReturn(Self.fixtureChromeJSON)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .any)
            .willThrow(StubError.notFound)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    @Test func `assets returns nil when rasterizer fails`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any).willReturn(Self.fixtureChromeJSON)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .any).willReturn(Data("X".utf8))
        given(rasterizer).rasterize(pdfData: .any).willThrow(StubError.notFound)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    // Drives `assemble` end-to-end with all four button anchors so the
    // anchor switch in computeMargins / buttonTopLeft is fully exercised.
    @Test func `assets composes a merged bezel for left right top and bottom buttons`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("composite".utf8), size: Size(width: 100, height: 200))
        let buttonImage = ChromeImage(data: Data("btn".utf8), size: Size(width: 10, height: 20))
        let merged = ChromeImage(data: Data("merged".utf8), size: Size(width: 120, height: 240))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONFourAnchors)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("PhoneComposite"))
            .willReturn(Data("composite-pdf".utf8))
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("BTN"))
            .willReturn(Data("btn-pdf".utf8))
        given(rasterizer).rasterize(pdfData: .value(Data("composite-pdf".utf8)))
            .willReturn(composite)
        given(rasterizer).rasterize(pdfData: .value(Data("btn-pdf".utf8)))
            .willReturn(buttonImage)
        given(rasterizer).compose(canvasSize: .any, layers: .any).willReturn(merged)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        let assets = chromes.assets(forDeviceName: "iPhone 17 Pro")

        #expect(assets?.composite == merged)
        // Margins reflect every anchor branch:
        //   left:   imgW(10) - offX(0) = 10
        //   right:  imgW(10) + offX(0) = 10
        //   top:    -(offY(-15) - imgH(20)/2) = 25
        //   bottom: offY(15) + imgH(20)/2 = 25
        #expect(assets?.buttonMargins == Insets(top: 25, left: 10, bottom: 25, right: 10))
        verify(rasterizer).compose(canvasSize: .any, layers: .any).called(1)
    }

    // When every button image fails to rasterize the merged-canvas path
    // is skipped — assets fall back to the bare composite, no compose call.
    @Test func `assets falls back to bare composite when every button image fails`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("c".utf8), size: Size(width: 100, height: 200))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONFourAnchors)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("PhoneComposite"))
            .willReturn(Data("composite-pdf".utf8))
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("BTN"))
            .willThrow(StubError.notFound)
        given(rasterizer).rasterize(pdfData: .value(Data("composite-pdf".utf8)))
            .willReturn(composite)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        let assets = chromes.assets(forDeviceName: "iPhone 17 Pro")

        #expect(assets?.composite == composite)
        #expect(assets?.buttonMargins == Insets(top: 0, left: 0, bottom: 0, right: 0))
        verify(rasterizer).compose(canvasSize: .any, layers: .any).called(0)
    }
}

// MARK: - fixtures

private extension LiveChromesTests {

    static let fixturePlist: Data = {
        try! PropertyListSerialization.data(
            fromPropertyList: [
                "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone11"
            ] as [String: Any],
            format: .xml, options: 0
        )
    }()

    static let fixtureChromeJSON: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": {
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 18, "rightWidth": 18, "topHeight": 18, "bottomHeight": 18 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 80, "cornerRadiusY": 80 } },
      "inputs": []
    }
    """#.utf8)

    static let fixtureChromeJSONNoComposite: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": { "sizing": { "leftWidth": 18, "rightWidth": 18, "topHeight": 18, "bottomHeight": 18 } },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 80 } },
      "inputs": []
    }
    """#.utf8)

    /// Four anchors × two aligns — drives every arm of the
    /// computeMargins / buttonTopLeft switches (left, right, top with
    /// both leading & trailing align, bottom with both leading & trailing).
    static let fixtureChromeJSONFourAnchors: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": {
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 0, "rightWidth": 0, "topHeight": 0, "bottomHeight": 0 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 0 } },
      "inputs": [
        { "name": "L",  "image": "BTN", "anchor": "left",   "align": "leading",
          "offsets": { "rollover": { "x": 0, "y": 50 } } },
        { "name": "R",  "image": "BTN", "anchor": "right",  "align": "leading",
          "offsets": { "rollover": { "x": 0, "y": 50 } } },
        { "name": "TT", "image": "BTN", "anchor": "top",    "align": "trailing",
          "offsets": { "rollover": { "x": 0, "y": -15 } } },
        { "name": "TL", "image": "BTN", "anchor": "top",    "align": "leading",
          "offsets": { "rollover": { "x": 0, "y": -15 } } },
        { "name": "BL", "image": "BTN", "anchor": "bottom", "align": "leading",
          "offsets": { "rollover": { "x": 0, "y": 15 } } },
        { "name": "BT", "image": "BTN", "anchor": "bottom", "align": "trailing",
          "offsets": { "rollover": { "x": 0, "y": 15 } } }
      ]
    }
    """#.utf8)
}

private enum StubError: Error { case notFound }
