import Foundation

/// What we read from a CoreSimulator device-type's `profile.plist`.
/// Today we only need the `chromeIdentifier` to find the matching
/// DeviceKit chrome bundle, so the value carries just that — keeps
/// the type honest. New fields (e.g. `mainScreenScale`) get added the
/// moment a caller actually needs them.
struct DeviceProfile: Equatable, Sendable {
    /// Bare bundle name like `"phone11"` or `"tablet5"`. The plist
    /// stores the full bundle id (`com.apple.dt.devicekit.chrome.phone11`);
    /// we strip the prefix at parse time so the rest of the system
    /// works in directory-name space.
    let chromeIdentifier: String
    /// Screen size in 1x points. Used by 9-slice chrome composition to
    /// size the inner canvas area, since DeviceKit's `Screen.pdf` is a
    /// meaningless 1×1 marker. `nil` when neither source carries one.
    ///
    /// Two sources, because Xcode 27 moved the numbers. Xcode ≤26 put
    /// `mainScreenWidth` / `mainScreenHeight` / `mainScreenScale` on the
    /// profile itself; Xcode 27 dropped all three (124 of 124 device
    /// types carry them on 26, 0 of 124 on 27) and publishes the same
    /// values in a sibling `capabilities.plist` instead.
    let screenSize: Size?
    /// A foldable's second panel, from `capabilities.plist`'s
    /// `primary-1` display. `nil` on every single-panel device.
    let secondaryPanel: PanelProfile?

    /// One of the device's own panels: its DeviceKit chrome and its
    /// screen in points. The primary is the profile itself; the
    /// secondary exists only on a foldable, where the hinge decides
    /// which of the two the bezel and the tap space describe.
    struct PanelProfile: Equatable, Sendable {
        let chromeIdentifier: String
        let screenSize: Size?
        /// The framebuffer mask CoreSimulator clips this panel with —
        /// `/Library/Developer/DeviceKit/FramebufferMasks/<id>.pdf`.
        /// The shape the simulator itself uses: iPhone Duo's cover has
        /// near-square corners on the hinge side and round ones on the
        /// outer edge, which `chrome.json`'s single radius cannot say.
        /// `nil` when the profile names none (Xcode ≤26).
        let framebufferMaskIdentifier: String?

        init(chromeIdentifier: String, screenSize: Size?, framebufferMaskIdentifier: String? = nil) {
            self.chromeIdentifier = chromeIdentifier
            self.screenSize = screenSize
            self.framebufferMaskIdentifier = framebufferMaskIdentifier
        }
    }

    /// The primary panel's mask, from the `primary` (or only) integrated
    /// display in `capabilities.plist`.
    let framebufferMaskIdentifier: String?

    var panels: [IntegratedPanel] {
        secondaryPanel == nil ? [.primary] : [.primary, .secondary]
    }

    func panel(_ panel: IntegratedPanel) -> PanelProfile? {
        switch panel {
        case .primary:
            return PanelProfile(
                chromeIdentifier: chromeIdentifier, screenSize: screenSize,
                framebufferMaskIdentifier: framebufferMaskIdentifier)
        case .secondary:
            return secondaryPanel
        }
    }

    init(
        chromeIdentifier: String,
        screenSize: Size?,
        secondaryPanel: PanelProfile? = nil,
        framebufferMaskIdentifier: String? = nil
    ) {
        self.chromeIdentifier = chromeIdentifier
        self.screenSize = screenSize
        self.secondaryPanel = secondaryPanel
        self.framebufferMaskIdentifier = framebufferMaskIdentifier
    }

    static func parsing(
        plistData data: Data,
        capabilitiesData: Data? = nil
    ) throws -> DeviceProfile {
        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            )
        } catch {
            throw DeviceProfileParseError.malformedPlist
        }
        guard let dict = raw as? [String: Any] else {
            throw DeviceProfileParseError.malformedPlist
        }
        guard let fullID = dict["chromeIdentifier"] as? String else {
            throw DeviceProfileParseError.missingChromeIdentifier
        }

        let displays = capabilitiesData.flatMap(integratedDisplays) ?? []
        let cover = displays.first { $0["deviceName"] as? String == "primary" } ?? displays.first
        let unfolded = displays.first { $0["deviceName"] as? String == "primary-1" }

        return DeviceProfile(
            chromeIdentifier: bareChromeIdentifier(fullID),
            screenSize: parseScreenSize(dict) ?? cover.flatMap(parseDisplaySize),
            secondaryPanel: unfolded.flatMap { panel in
                guard let id = panel["chromeIdentifier"] as? String else { return nil }
                return PanelProfile(
                    chromeIdentifier: bareChromeIdentifier(id),
                    screenSize: parseDisplaySize(panel),
                    framebufferMaskIdentifier: panel["framebufferMaskIdentifier"] as? String
                )
            },
            framebufferMaskIdentifier: cover?["framebufferMaskIdentifier"] as? String
        )
    }

    private static func bareChromeIdentifier(_ fullID: String) -> String {
        let prefix = "com.apple.dt.devicekit.chrome."
        return fullID.hasPrefix(prefix) ? String(fullID.dropFirst(prefix.count)) : fullID
    }

    /// Xcode 27's `capabilities.plist` → `capabilities.displays`, a list
    /// describing every panel the device can drive. Only the
    /// `integrated` entries are the device's own screens: the others are
    /// `tvOut` and `carPlay` (both 720×480) and a `scene` entry at
    /// 7680×4320 for resizable windows. Sizing a bezel off any of those
    /// would be silently, wildly wrong, so the type is matched
    /// explicitly rather than taking the first element.
    ///
    /// A foldable lists two `integrated` panels. iPhone Duo's cover is
    /// `deviceName: primary` (1398×2034, `phone15`) and its unfolded
    /// panel is `primary-1` (2007×2853, `phone14`). The cover is the
    /// profile's own screen; the unfolded one is `secondaryPanel`. Any
    /// integrated entry is the fallback for the single-panel devices
    /// that predate the name.
    private static func integratedDisplays(_ data: Data) -> [[String: Any]]? {
        guard let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let root = raw as? [String: Any],
              let capabilities = root["capabilities"] as? [String: Any],
              let displays = capabilities["displays"] as? [[String: Any]]
        else { return nil }
        return displays.filter { $0["displayType"] as? String == "integrated" }
    }

    /// Same arithmetic as `parseScreenSize`, over the capabilities
    /// spelling of the keys.
    private static func parseDisplaySize(_ dict: [String: Any]) -> Size? {
        guard let w = dict["width"] as? Double,
              let h = dict["height"] as? Double,
              let s = dict["scale"] as? Double,
              s > 0
        else { return nil }
        return Size(width: w / s, height: h / s)
    }

    /// Plist values are NSNumber-bridged; `as? Double` covers integer
    /// and float literals alike. All three keys must be present and the
    /// scale non-zero — anything else returns nil rather than producing
    /// a degenerate size.
    private static func parseScreenSize(_ dict: [String: Any]) -> Size? {
        guard let w = dict["mainScreenWidth"] as? Double,
              let h = dict["mainScreenHeight"] as? Double,
              let s = dict["mainScreenScale"] as? Double,
              s > 0
        else { return nil }
        return Size(width: w / s, height: h / s)
    }
}

enum DeviceProfileParseError: Error, Equatable {
    case malformedPlist
    case missingChromeIdentifier
}
