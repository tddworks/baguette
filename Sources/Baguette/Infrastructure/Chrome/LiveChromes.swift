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
        guard let profile = resolveProfile(deviceName: deviceName) else {
            return nil
        }
        let chromeID = profile.chromeIdentifier

        lock.lock()
        if let cached = cache[chromeID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = loadAssets(chromeIdentifier: chromeID, profile: profile)

        lock.lock()
        cache[chromeID] = resolved
        lock.unlock()
        return resolved
    }

    // MARK: - private

    private func resolveProfile(deviceName: String) -> DeviceProfile? {
        do {
            let plistData = try store.profilePlistData(deviceName: deviceName)
            return try DeviceProfile.parsing(plistData: plistData)
        } catch {
            return nil
        }
    }

    private func loadAssets(
        chromeIdentifier: String,
        profile: DeviceProfile
    ) -> DeviceChromeAssets? {
        let chrome: DeviceChrome
        do {
            let json = try store.chromeJSONData(chromeIdentifier: chromeIdentifier)
            chrome = try DeviceChrome.parsing(json: json)
        } catch {
            return nil
        }
        guard let composite = loadComposite(
            chromeIdentifier: chromeIdentifier,
            chrome: chrome,
            profile: profile
        ) else {
            // Neither baked-composite nor a complete 9-slice (with a
            // valid screen size) — cache nil so we don't keep re-parsing.
            return nil
        }
        do {
            return try assemble(
                chromeIdentifier: chromeIdentifier,
                chrome: chrome,
                composite: composite
            )
        } catch {
            return nil
        }
    }

    /// Resolve a `DeviceChrome` to a single bezel image. Prefers the
    /// pre-baked composite when the bundle ships one (every iPhone
    /// `phoneN ≤ 12`); falls through to 9-slice composition for
    /// bundles that ship only corner / edge pieces (every iPad
    /// `tabletN`, plus `phone13` for iPhone 17e). The 9-slice path
    /// needs the simulator's screen size to size its inner canvas —
    /// `Screen.pdf` is a 1×1 marker, so we read the dimensions from
    /// `mainScreen{Width,Height,Scale}` on the device's plist instead.
    private func loadComposite(
        chromeIdentifier: String,
        chrome: DeviceChrome,
        profile: DeviceProfile
    ) -> ChromeImage? {
        if let imageName = chrome.compositeImageName,
           let pdf = try? store.chromeAssetPDF(
               chromeIdentifier: chromeIdentifier, imageName: imageName
           ),
           let composite = try? rasterizer.rasterize(pdfData: pdf) {
            return composite
        }
        guard let slice = chrome.slice,
              let innerSize = profile.screenSize,
              let pdfs = loadSlicePDFs(
                  chromeIdentifier: chromeIdentifier, slice: slice
              ) else {
            return nil
        }
        return try? rasterizer.compose9Slice(
            pdfs: pdfs, insets: chrome.screenInsets, innerSize: innerSize
        )
    }

    /// Read all nine PDF assets in one go. Any single missing piece
    /// fails the whole load — a half-drawn bezel would look worse than
    /// no bezel.
    private func loadSlicePDFs(
        chromeIdentifier: String,
        slice: DeviceChromeSlice
    ) -> NineSlicePDFs? {
        func read(_ name: String) throws -> Data {
            try store.chromeAssetPDF(
                chromeIdentifier: chromeIdentifier, imageName: name
            )
        }
        do {
            return try NineSlicePDFs(
                topLeft: read(slice.topLeft),
                top: read(slice.top),
                topRight: read(slice.topRight),
                right: read(slice.right),
                bottomRight: read(slice.bottomRight),
                bottom: read(slice.bottom),
                bottomLeft: read(slice.bottomLeft),
                left: read(slice.left)
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
            return DeviceChromeAssets(
                chrome: chrome,
                composite: composite,
                bareComposite: composite,
                buttonImages: [:]
            )
        }

        // Retain the per-button rasterized PNGs keyed by name so the
        // server can hand them out via `/chrome-button/<name>.png` for
        // the actionable-bezel UI. Map preserves insertion order for
        // the unlikely case of duplicate names — last-write wins,
        // matching how the merger picks the top layer.
        //
        // When the chrome ships an `imageDown` variant we also
        // rasterize and stash it under `<name>-down` so the front
        // end can swap to a depressed sprite on `mousedown` (the
        // macOS Tahoe Simulator look). A failed down rasterize is
        // non-fatal — the press animation just falls back to the
        // pure positional depress.
        var perButton: [String: ChromeImage] = [:]
        perButton.reserveCapacity(buttonImages.count)
        for entry in buttonImages {
            perButton[entry.button.name] = entry.image
            if let downName = entry.button.imageDownName,
               let pdf = try? store.chromeAssetPDF(
                   chromeIdentifier: chromeIdentifier, imageName: downName
               ),
               let downImage = try? rasterizer.rasterize(pdfData: pdf) {
                perButton["\(entry.button.name)-down"] = downImage
            }
        }

        let margins = computeMargins(buttons: buttonImages)
        let canvasSize = Size(
            width:  composite.size.width  + margins.left + margins.right,
            height: composite.size.height + margins.top  + margins.bottom
        )

        // `onTop: false` buttons sit BEHIND the composite (only the
        // edge-overshoot survives — iPhone volume / power buttons).
        // `onTop: true` buttons sit ON TOP (Apple Watch's orange action
        // button, plus crown / side button on older watch chromes that
        // don't bake them into the composite). The rasterizer draws
        // layers back-to-front, so behind-buttons → composite → on-top
        // buttons is the right order.
        let behindLayers: [ImageLayer] = buttonImages
            .filter { !$0.button.onTop }
            .map { entry in
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
        let onTopLayers: [ImageLayer] = buttonImages
            .filter { $0.button.onTop }
            .map { entry in
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
        var layers = behindLayers
        layers.append(ImageLayer(
            image: composite,
            topLeft: Point(x: margins.left, y: margins.top)
        ))
        layers.append(contentsOf: onTopLayers)

        let merged = try rasterizer.compose(canvasSize: canvasSize, layers: layers)
        return DeviceChromeAssets(
            chrome: chrome,
            composite: merged,
            bareComposite: composite,
            buttonImages: perButton,
            buttonMargins: margins
        )
    }

    /// Overshoot margins — how far each button image extends past the
    /// composite edge along its anchored side. Used to expand the
    /// merged-bezel canvas so the cap visually pokes out instead of
    /// being clipped at the device-body edge.
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
    /// canvas. Returns the point passed to `compose(...)`'s layer
    /// geometry.
    ///
    /// chrome.json semantics for the four anchors (verified against
    /// Apple's Simulator):
    ///   • LEFT / RIGHT: `x` is the image's CENTRE inside the bezel
    ///     (cap straddles the side rail). `y` is the image's TOP
    ///     edge, NOT its centre — the convention scales with image
    ///     height: a 16-px-tall action cap and a 101-px-tall power
    ///     cap with the same y both START at the same y, so offsets
    ///     line up with native rendering. Treating y as centre
    ///     drifts taller caps downward by half-image-height (~5% of
    ///     bezel for the power button).
    ///   • TOP / BOTTOM: same y-as-edge logic on the perpendicular
    ///     axis (x is CENTRE, y is the offset from the bezel edge).
    private func buttonTopLeft(
        button: ChromeButton,
        imageSize: Size,
        compositeSize: Size,
        margins: Insets
    ) -> Point {
        let compX = margins.left
        let compY = margins.top
        let cx: Double  // image CENTRE on x
        let topY: Double  // image TOP-LEFT y (already the value we return)
        switch button.anchor {
        case .left:
            cx = compX + button.offset.x
            topY = compY + button.offset.y
        case .right:
            cx = compX + compositeSize.width + button.offset.x
            topY = compY + button.offset.y
        case .top:
            let baseX = button.align == .trailing
                ? compX + compositeSize.width
                : compX
            cx = baseX + button.offset.x
            topY = compY + button.offset.y
        case .bottom:
            let baseX = button.align == .trailing
                ? compX + compositeSize.width
                : compX
            cx = baseX + button.offset.x
            topY = compY + compositeSize.height + button.offset.y
        }
        return Point(x: cx - imageSize.width / 2, y: topY)
    }
}
