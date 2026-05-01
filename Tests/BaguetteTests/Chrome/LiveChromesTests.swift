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
}

private enum StubError: Error { case notFound }
