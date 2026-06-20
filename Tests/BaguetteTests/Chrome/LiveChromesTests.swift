import Testing
import Foundation
import Mockable
@testable import BaguetteCore

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

    @Test func `assets returns nil when chrome has neither composite nor full slice`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONNoComposite)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        // No composite, no slice — nothing to render. Caller can fall
        // back to a plain stream.
        #expect(chromes.assets(forDeviceName: "iPhone 17 Pro") == nil)
    }

    @Test func `assets composes a 9-slice bezel using screen size from plist`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composed = ChromeImage(data: Data("9SLICE-PNG".utf8), size: Size(width: 926, height: 1302))

        // tablet5 plist with mainScreenWidth/Height/Scale → 1668/2 ×
        // 2420/2 = 834×1210 1× points (iPad Pro 11" M4).
        given(store).profilePlistData(deviceName: .any)
            .willReturn(Self.makePlist(
                chromeIdentifier: "com.apple.dt.devicekit.chrome.tablet5",
                width: 1668, height: 2420, scale: 2
            ))
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONSliceOnly)
        for (name, payload) in Self.slicePDFNamesAndPayloads where name != "Screen" {
            given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value(name))
                .willReturn(Data(payload.utf8))
        }
        given(rasterizer).compose9Slice(pdfs: .any, insets: .any, innerSize: .any)
            .willReturn(composed)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        let assets = try #require(chromes.assets(forDeviceName: "iPad Pro 11-inch (M4)"))

        #expect(assets.composite == composed)
        verify(rasterizer).compose9Slice(
            pdfs: .value(NineSlicePDFs(
                topLeft: Data("topLeft".utf8),
                top: Data("top".utf8),
                topRight: Data("topRight".utf8),
                right: Data("right".utf8),
                bottomRight: Data("bottomRight".utf8),
                bottom: Data("bottom".utf8),
                bottomLeft: Data("bottomLeft".utf8),
                left: Data("left".utf8)
            )),
            insets: .value(Insets(top: 46, left: 46, bottom: 46, right: 46)),
            innerSize: .value(Size(width: 834, height: 1210))
        ).called(1)
        // No baked composite means we must NOT call rasterize on a
        // single composite PDF.
        verify(rasterizer).rasterize(pdfData: .any).called(0)
    }

    @Test func `assets returns nil for 9-slice bundle when plist lacks screen size`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        // chromeIdentifier present but mainScreen* keys missing — the
        // 9-slice path can't size the canvas, so the asset is unloadable.
        given(store).profilePlistData(deviceName: .any)
            .willReturn(Self.makePlist(
                chromeIdentifier: "com.apple.dt.devicekit.chrome.tablet5"
            ))
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONSliceOnly)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        #expect(chromes.assets(forDeviceName: "iPad Pro 11-inch (M4)") == nil)
    }

    @Test func `assets returns nil when a 9-slice piece is unreadable`() {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONSliceOnly)
        // 8 of 9 readable, one missing — overall result must be nil
        // (a half-drawn bezel is worse than no bezel).
        for (name, _) in Self.slicePDFNamesAndPayloads where name != "iPadTop" {
            given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value(name))
                .willReturn(Data("ok".utf8))
        }
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("iPadTop"))
            .willThrow(StubError.notFound)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
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
        // Margins come from chrome.json's `images.devicePadding`,
        // verbatim — Apple's authoritative source. The four-anchor
        // fixture declares (top:7, left:3, bottom:5, right:9); button
        // geometry no longer drives this value.
        #expect(assets?.buttonMargins == Insets(top: 7, left: 3, bottom: 5, right: 9))
        verify(rasterizer).compose(canvasSize: .any, layers: .any).called(1)
    }

    // Apple's chrome.json carries an authoritative `images.devicePadding`
    // block — the canvas margin reserved around the rasterized
    // composite for hardware-button overshoot and rollover-animation
    // slack. The merged bezel must take its margins straight from
    // that field, not from button-geometry guessing: real chromes
    // ship `devicePadding` even on tablet bundles that have no
    // buttons at all, and the values for watches don't match the
    // naive "imgW ± offX" inference.
    //
    // Fixture: composite 100×200, single right-anchor button image
    // 20×60 with its CENTRE 25 px inside the composite right edge
    // (button sits entirely inside the composite — the inferred
    // overshoot is zero). chrome.devicePadding declares `right: 11`
    // for hover popout. Assertion: merged margins reflect that 11 —
    // not the zero an inference formula would compute, and not the
    // accidental `imgW + offX` = -5 → 0 the prior production code
    // would compute.
    @Test func `assets uses chrome devicePadding as button margins`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("composite".utf8), size: Size(width: 100, height: 200))
        let sideBtn = ChromeImage(data: Data("side".utf8), size: Size(width: 20, height: 60))
        let merged = ChromeImage(data: Data("merged".utf8), size: Size(width: 111, height: 200))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONDevicePadding)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("PhoneComposite"))
            .willReturn(Data("composite-pdf".utf8))
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("SIDE"))
            .willReturn(Data("side-pdf".utf8))
        given(rasterizer).rasterize(pdfData: .value(Data("composite-pdf".utf8)))
            .willReturn(composite)
        given(rasterizer).rasterize(pdfData: .value(Data("side-pdf".utf8)))
            .willReturn(sideBtn)
        given(rasterizer).compose(canvasSize: .any, layers: .any).willReturn(merged)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        let assets = chromes.assets(forDeviceName: "Apple Watch Ultra 2 (49mm)")

        #expect(assets?.buttonMargins == Insets(top: 0, left: 0, bottom: 0, right: 11))
        verify(rasterizer).compose(
            canvasSize: .value(Size(width: 111, height: 200)),
            layers: .any
        ).called(1)
    }

    // Right-anchor buttons position their image's LEFT (inner) edge
    // at `composite.width + (2 * normalOffset.x - rolloverOffset.x)`.
    //
    // chrome.json's `normalOffset` is the HOVER position (the cap
    // popped out a few px past the body); at-rest mirrors the
    // rollover delta INWARD so a button with `normal=-30`,
    // `rollover=-25` rests at `-35` (1 px protrusion) and animates
    // outward by 5 chrome-px on hover to `-30` (6 px protrusion).
    // For buttons without a hover animation (`normal == rollover`,
    // e.g. watch4 DigitalCrown) the formula collapses to
    // `normalOffset.x` and the cap stays at its single position.
    //
    // A naive "at-rest = normalOffset" interpretation landed wide
    // caps (SideButton 36 wide) too far past the rail at rest —
    // user's feedback was that the chrome.json normal position
    // looks like a hovered state, not a relaxed one (Image #14 +
    // "this offset should be when it's hovered").
    //
    // Fixture: right-anchor button with normal=(-30, 160),
    // rollover=(-25, 160), image 36×67, on a 100×200 composite.
    // Expected layer top-left:
    //   x = composite.width + (2 * -30 - -25) = 100 - 35 = 65
    //   y = 2 * 160 - 160 = 160  (TOP-edge convention; y delta is
    //                             zero on horizontal-only animations)
    @Test func `assets positions right-anchor button mirroring rollover delta inward`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("c".utf8), size: Size(width: 100, height: 200))
        let btn = ChromeImage(data: Data("b".utf8), size: Size(width: 36, height: 67))
        let merged = ChromeImage(data: Data("m".utf8), size: Size(width: 106, height: 200))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONRightAnchorHover)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("PhoneComposite"))
            .willReturn(Data("composite-pdf".utf8))
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("SIDE"))
            .willReturn(Data("side-pdf".utf8))
        given(rasterizer).rasterize(pdfData: .value(Data("composite-pdf".utf8)))
            .willReturn(composite)
        given(rasterizer).rasterize(pdfData: .value(Data("side-pdf".utf8)))
            .willReturn(btn)
        given(rasterizer).compose(canvasSize: .any, layers: .any).willReturn(merged)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        _ = chromes.assets(forDeviceName: "Apple Watch Ultra 2 (49mm)")

        verify(rasterizer).compose(
            canvasSize: .any,
            layers: .matching { layers in
                guard let layer = layers.first(where: { $0.image == btn }) else { return false }
                return layer.topLeft == Point(x: 65, y: 160)
            }
        ).called(1)
    }

    // Watch-style chrome: the orange action button (`onTop: true`)
    // must layer ON TOP of the composite, otherwise the bezel hides
    // it. Older watch chromes (watch ≤ watch5b/5s) have the same need
    // for the digital crown and side button, so honoring `onTop` fixes
    // every watch family in one go.
    @Test func `assets layers onTop buttons above the composite`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("composite".utf8), size: Size(width: 100, height: 200))
        let behind = ChromeImage(data: Data("behind".utf8), size: Size(width: 10, height: 20))
        let onTop = ChromeImage(data: Data("ontop".utf8), size: Size(width: 8, height: 30))
        let merged = ChromeImage(data: Data("merged".utf8), size: Size(width: 110, height: 200))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        given(store).chromeJSONData(chromeIdentifier: .any)
            .willReturn(Self.fixtureChromeJSONOnTopMix)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("PhoneComposite"))
            .willReturn(Data("composite-pdf".utf8))
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("BEHIND"))
            .willReturn(Data("behind-pdf".utf8))
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .value("ONTOP"))
            .willReturn(Data("ontop-pdf".utf8))
        given(rasterizer).rasterize(pdfData: .value(Data("composite-pdf".utf8)))
            .willReturn(composite)
        given(rasterizer).rasterize(pdfData: .value(Data("behind-pdf".utf8)))
            .willReturn(behind)
        given(rasterizer).rasterize(pdfData: .value(Data("ontop-pdf".utf8)))
            .willReturn(onTop)
        given(rasterizer).compose(canvasSize: .any, layers: .any).willReturn(merged)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        _ = chromes.assets(forDeviceName: "Apple Watch Ultra 2 (49mm)")

        // Layers must be: behind-button → composite → onTop-button.
        // Compare by image identity (data) since `ImageLayer`'s topLeft
        // depends on margin math we don't want to re-derive here.
        verify(rasterizer).compose(
            canvasSize: .any,
            layers: .matching { layers in
                layers.count == 3
                    && layers[0].image == behind
                    && layers[1].image == composite
                    && layers[2].image == onTop
            }
        ).called(1)
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

    // MARK: - bare composite + per-button images (actionable bezel)
    //
    // The actionable-bezel UI needs the device body without the
    // buttons baked in (so it can layer per-button images on top
    // and animate them). LiveChromes already rasterizes each
    // button individually in `assemble`; these tests pin the
    // requirement that those individual images and the bare
    // composite are *retained* on the returned assets, instead of
    // being dropped after the merge.

    @Test func `assets retains the bare composite separate from the merged composite`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("composite-bare".utf8), size: Size(width: 100, height: 200))
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

        // `composite` is the merged bezel (today's behavior).
        // `bareComposite` is the device body alone — the new contract.
        #expect(assets?.composite == merged)
        #expect(assets?.bareComposite == composite)
    }

    @Test func `assets retains every button image keyed by name`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let composite = ChromeImage(data: Data("c".utf8), size: Size(width: 100, height: 200))
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

        // FourAnchors fixture has six inputs (L, R, TT, TL, BL, BT)
        // — every name should map to the rasterized button image.
        let images = try #require(assets?.buttonImages)
        #expect(Set(images.keys) == ["L", "R", "TT", "TL", "BL", "BT"])
        for (_, img) in images {
            #expect(img == buttonImage)
        }
    }

    @Test func `assets falls back bareComposite to composite when chrome has no buttons`() throws {
        let store = MockChromeStore()
        let rasterizer = MockPDFRasterizer()
        let pdf = Data("pdf".utf8)
        let composite = ChromeImage(data: Data("c".utf8), size: Size(width: 1, height: 1))

        given(store).profilePlistData(deviceName: .any).willReturn(Self.fixturePlist)
        // fixtureChromeJSON has `"inputs": []` — no buttons, no merge.
        given(store).chromeJSONData(chromeIdentifier: .any).willReturn(Self.fixtureChromeJSON)
        given(store).chromeAssetPDF(chromeIdentifier: .any, imageName: .any).willReturn(pdf)
        given(rasterizer).rasterize(pdfData: .any).willReturn(composite)

        let chromes = LiveChromes(store: store, rasterizer: rasterizer)
        let assets = chromes.assets(forDeviceName: "iPhone 17 Pro")

        // No buttons → bare and merged are the same image; per-button
        // dictionary is empty. The contract has to hold for the
        // no-button case so callers don't need a special path.
        #expect(assets?.composite == composite)
        #expect(assets?.bareComposite == composite)
        #expect(assets?.buttonImages.isEmpty == true)
    }
}

// MARK: - fixtures

private extension LiveChromesTests {

    /// Default plist fixture — phone11 with a phone-shaped 1× point
    /// screen size (iPhone 17 Pro). 1320×2868 ÷ 3 = 440×956.
    static let fixturePlist: Data = makePlist(
        chromeIdentifier: "com.apple.dt.devicekit.chrome.phone11",
        width: 1320, height: 2868, scale: 3
    )

    /// Build a `profile.plist` with the keys `LiveChromes` reads:
    /// `chromeIdentifier` always, `mainScreen{Width,Height,Scale}` only
    /// when supplied — omitting the screen keys exercises the path
    /// where 9-slice composition can't size its inner canvas.
    static func makePlist(
        chromeIdentifier: String,
        width: Int? = nil,
        height: Int? = nil,
        scale: Int? = nil
    ) -> Data {
        var dict: [String: Any] = ["chromeIdentifier": chromeIdentifier]
        if let width  { dict["mainScreenWidth"]  = width }
        if let height { dict["mainScreenHeight"] = height }
        if let scale  { dict["mainScreenScale"]  = scale }
        return try! PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
    }

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

    /// Real-shape `tablet5` chrome — every iPad bundle's 9-slice
    /// (and `phone13` / iPhone 17e) parses to this same shape.
    static let fixtureChromeJSONSliceOnly: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.tablet5",
      "images": {
        "topLeft": "iPadTL",
        "top": "iPadTop",
        "topRight": "iPadTR",
        "right": "iPadRight",
        "bottomRight": "iPadBR",
        "bottom": "iPadBase",
        "bottomLeft": "iPadBL",
        "left": "iPadLeft",
        "screen": "Screen",
        "sizing": { "leftWidth": 46, "rightWidth": 46, "topHeight": 46, "bottomHeight": 46 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 75 } },
      "inputs": []
    }
    """#.utf8)

    /// Map of slice asset name → mock PDF payload, used by the 9-slice
    /// happy-path test to assert the right `imageName` lookups happen
    /// and the right bytes flow into `compose9Slice`. The `Screen` entry
    /// stays here only so the 'unreadable piece' test can stub /
    /// throw without special-casing — `compose9Slice` itself never
    /// receives the screen PDF (1×1 marker, supplanted by `innerSize`).
    static let slicePDFNamesAndPayloads: [(String, String)] = [
        ("iPadTL",    "topLeft"),
        ("iPadTop",   "top"),
        ("iPadTR",    "topRight"),
        ("iPadRight", "right"),
        ("iPadBR",    "bottomRight"),
        ("iPadBase",  "bottom"),
        ("iPadBL",    "bottomLeft"),
        ("iPadLeft",  "left"),
    ]

    /// watch4-shape fixture exposing the new authoritative source for
    /// canvas margins: `images.devicePadding`. The right-anchor button
    /// fits ENTIRELY inside the composite (centre 25 px in, image 36
    /// wide → right edge 7 px before composite right edge), so an
    /// inference-based formula would compute zero overshoot. The
    /// chrome's declared `right: 11` is therefore the only thing that
    /// can produce the correct 11 px hover-popout margin.
    static let fixtureChromeJSONDevicePadding: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.watch4",
      "images": {
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 0, "rightWidth": 0, "topHeight": 0, "bottomHeight": 0 },
        "devicePadding": { "top": 0, "left": 0, "bottom": 0, "right": 11 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 0 } },
      "inputs": [
        { "name": "side", "image": "SIDE", "anchor": "right",
          "offsets": { "normal": { "x": -25, "y": 160 } } }
      ]
    }
    """#.utf8)

    /// One `onTop: false` button and one `onTop: true` button. Drives
    /// the layering split inside `assemble()` so a watch-shaped chrome
    /// renders its overlaid action button above the bezel.
    /// Right-anchor button with distinct normal / rollover offsets
    /// (the side-button "has hover" case). normal=(-30, 160),
    /// rollover=(-25, 160), image 36×67, on a 100-wide composite,
    /// devicePadding.right=6 so the merged canvas (composite +
    /// margins) is exactly 106 wide and the at-rest cap right edge
    /// (100 - 30 + 36 = 106) lands flush with the canvas right edge.
    static let fixtureChromeJSONRightAnchorHover: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.watch4",
      "images": {
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 0, "rightWidth": 0, "topHeight": 0, "bottomHeight": 0 },
        "devicePadding": { "top": 0, "left": 0, "bottom": 0, "right": 6 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 0 } },
      "inputs": [
        { "name": "side", "image": "SIDE", "anchor": "right",
          "offsets": { "normal": { "x": -30, "y": 160 }, "rollover": { "x": -25, "y": 160 } } }
      ]
    }
    """#.utf8)

    static let fixtureChromeJSONOnTopMix: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.watch4",
      "images": {
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 0, "rightWidth": 0, "topHeight": 0, "bottomHeight": 0 }
      },
      "paths": { "simpleOutsideBorder": { "cornerRadiusX": 0 } },
      "inputs": [
        { "name": "behind", "image": "BEHIND", "anchor": "left",
          "onTop": false,
          "offsets": { "normal": { "x": 0, "y": 50 } } },
        { "name": "onTop", "image": "ONTOP", "anchor": "left",
          "onTop": true,
          "offsets": { "normal": { "x": 20, "y": 100 } } }
      ]
    }
    """#.utf8)

    /// Four anchors × two aligns — drives every arm of the
    /// `buttonTopLeft` switch (left, right, top with both leading &
    /// trailing align, bottom with both leading & trailing). Carries
    /// a non-trivial `devicePadding` block so the test can pin that
    /// Apple's authoritative margin flows through to the assets.
    static let fixtureChromeJSONFourAnchors: Data = Data(#"""
    {
      "identifier": "com.apple.dt.devicekit.chrome.phone11",
      "images": {
        "composite": "PhoneComposite",
        "sizing": { "leftWidth": 0, "rightWidth": 0, "topHeight": 0, "bottomHeight": 0 },
        "devicePadding": { "top": 7, "left": 3, "bottom": 5, "right": 9 }
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
