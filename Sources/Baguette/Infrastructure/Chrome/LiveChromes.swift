import Foundation

/// Production `Chromes` — composes a filesystem `ChromeStore` and a
/// `PDFRasterizer` to turn a `Simulator` into a `DeviceChromeAssets`.
///
/// Caches by `chromeIdentifier`, not by simulator UDID — many
/// simulators share the same chrome bundle (every iPhone 17 variant
/// uses `phone11`), and the rasterized PNG isn't device-specific.
/// The plist read still happens per call because that's what tells
/// us *which* bundle to look up; it's a few hundred bytes off SSD
/// and not the bottleneck.
///
/// Every error path collapses to `nil` at the public boundary —
/// the caller decides whether to fall back to a plain stream or
/// surface "no bezel for this device". Reasoning lives in stderr
/// logs (the system already routes those).
final class LiveChromes: Chromes, @unchecked Sendable {
    private let store: any ChromeStore
    private let rasterizer: any PDFRasterizer

    private let lock = NSLock()
    /// Guarded by `lock`. Bundles without a composite cache `nil`
    /// so we don't re-read their chrome.json on every call.
    private var cache: [String: DeviceChromeAssets?] = [:]

    init(store: any ChromeStore, rasterizer: any PDFRasterizer) {
        self.store = store
        self.rasterizer = rasterizer
    }

    func assets(forDeviceName deviceName: String) -> DeviceChromeAssets? {
        guard let chromeID = chromeIdentifier(forDeviceName: deviceName) else {
            return nil
        }

        lock.lock()
        if let cached = cache[chromeID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = loadAssets(chromeIdentifier: chromeID)

        lock.lock()
        cache[chromeID] = resolved
        lock.unlock()
        return resolved
    }

    // MARK: - private

    private func chromeIdentifier(forDeviceName deviceName: String) -> String? {
        do {
            let plistData = try store.profilePlistData(deviceName: deviceName)
            return try DeviceProfile.parsing(plistData: plistData).chromeIdentifier
        } catch {
            return nil
        }
    }

    private func loadAssets(chromeIdentifier: String) -> DeviceChromeAssets? {
        let chrome: DeviceChrome
        do {
            let json = try store.chromeJSONData(chromeIdentifier: chromeIdentifier)
            chrome = try DeviceChrome.parsing(json: json)
        } catch {
            return nil
        }
        guard let imageName = chrome.compositeImageName else {
            // 9-slice-only bundles aren't supported yet; cache nil so
            // we don't keep re-parsing the JSON.
            return nil
        }
        do {
            let pdf = try store.chromeAssetPDF(
                chromeIdentifier: chromeIdentifier,
                imageName: imageName
            )
            let composite = try rasterizer.rasterize(pdfData: pdf)
            return try assemble(
                chromeIdentifier: chromeIdentifier,
                chrome: chrome,
                composite: composite
            )
        } catch {
            return nil
        }
    }

    /// Rasterize the chrome's input buttons and stack them behind the
    /// device composite into a single PNG. The merged canvas grows
    /// outward by however much each button overshoots — that growth
    /// is recorded as `buttonMargins` on the returned assets, NOT
    /// folded into `chrome.screenInsets`. That keeps `bezelWidth` and
    /// `innerCornerRadius` at their parse-time values, so the
    /// screen's corner curve is unaffected by the bake-in. Buttons
    /// that fail to load are skipped — their absence shouldn't kill
    /// the bezel.
    private func assemble(
        chromeIdentifier: String,
        chrome: DeviceChrome,
        composite: ChromeImage
    ) throws -> DeviceChromeAssets {
        let buttonImages: [(button: ChromeButton, image: ChromeImage)] =
            chrome.buttons.compactMap { button in
                guard
                    let pdf = try? store.chromeAssetPDF(
                        chromeIdentifier: chromeIdentifier,
                        imageName: button.imageName
                    ),
                    let image = try? rasterizer.rasterize(pdfData: pdf)
                else { return nil }
                return (button, image)
            }

        if buttonImages.isEmpty {
            return DeviceChromeAssets(chrome: chrome, composite: composite)
        }

        let margins = computeMargins(buttons: buttonImages)
        let canvasSize = Size(
            width:  composite.size.width  + margins.left + margins.right,
            height: composite.size.height + margins.top  + margins.bottom
        )

        var layers: [ImageLayer] = buttonImages.map { entry in
            ImageLayer(
                image: entry.image,
                topLeft: buttonTopLeft(
                    button: entry.button,
                    imageSize: entry.image.size,
                    compositeSize: composite.size,
                    margins: margins
                )
            )
        }
        layers.append(ImageLayer(
            image: composite,
            topLeft: Point(x: margins.left, y: margins.top)
        ))

        let merged = try rasterizer.compose(canvasSize: canvasSize, layers: layers)
        return DeviceChromeAssets(
            chrome: chrome,
            composite: merged,
            buttonMargins: margins
        )
    }

    /// Overshoot margins — how far each button image extends past the
    /// composite edge along its anchored side. Ported from kittyfarm's
    /// chrome shell so visual parity is preserved across the two
    /// clients.
    private func computeMargins(
        buttons: [(button: ChromeButton, image: ChromeImage)]
    ) -> Insets {
        var top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0
        for entry in buttons {
            let imgW = entry.image.size.width
            let imgH = entry.image.size.height
            let offX = entry.button.offset.x
            let offY = entry.button.offset.y
            switch entry.button.anchor {
            case .left:   left   = max(left,   max(imgW - offX, 0))
            case .right:  right  = max(right,  max(imgW + offX, 0))
            case .top:    top    = max(top,    max(-(offY - imgH / 2), 0))
            case .bottom: bottom = max(bottom, max(offY + imgH / 2, 0))
            }
        }
        return Insets(top: top, left: left, bottom: bottom, right: right)
    }

    /// Top-left draw position for a button image inside the expanded
    /// canvas. Kittyfarm anchors the button image's *centre* at
    /// `(compX + offset.x, compY + offset.y)` (and the analogous
    /// anchor-derived points); this converts that centre to a
    /// top-left for `compose(...)`'s layer geometry.
    private func buttonTopLeft(
        button: ChromeButton,
        imageSize: Size,
        compositeSize: Size,
        margins: Insets
    ) -> Point {
        let compX = margins.left
        let compY = margins.top
        let cx: Double
        let cy: Double
        switch button.anchor {
        case .left:
            cx = compX + button.offset.x
            cy = compY + button.offset.y
        case .right:
            cx = compX + compositeSize.width + button.offset.x
            cy = compY + button.offset.y
        case .top:
            let baseX = button.align == .trailing
                ? compX + compositeSize.width
                : compX
            cx = baseX + button.offset.x
            cy = compY + button.offset.y
        case .bottom:
            let baseX = button.align == .trailing
                ? compX + compositeSize.width
                : compX
            cx = baseX + button.offset.x
            cy = compY + compositeSize.height + button.offset.y
        }
        return Point(x: cx - imageSize.width / 2, y: cy - imageSize.height / 2)
    }
}
