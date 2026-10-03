import Foundation

/// One connected screen from `simctl io enumerate`'s Connected Screens
/// section. Creatable entries are never represented here.
struct ConnectedScreenRecord: Sendable, Equatable {
    enum ScreenType: String, Sendable, Equatable {
        case integrated = "Integrated"
        case tvOut = "TVOut"
        case carPlay = "CarPlay"
        case unknown
    }

    let screenId: UInt32
    let name: String
    let screenType: ScreenType
    let size: Size
    /// CoreSimulator's own name for the panel — `primary`, `primary-1`,
    /// `external-0`, `wireless0`, `resizable`. Empty when the output
    /// predates the `Device Name:` line.
    let deviceName: String
    /// The guest's interface orientation on this screen, when it
    /// reports one. A foldable turns its unfolded panel to landscape by
    /// itself, and this is the only host-side word of it.
    let uiOrientation: DeviceOrientation?
    let scale: Double?

    init(
        screenId: UInt32,
        name: String,
        screenType: ScreenType,
        size: Size,
        deviceName: String = "",
        uiOrientation: DeviceOrientation? = nil,
        scale: Double? = nil
    ) {
        self.screenId = screenId
        self.name = name
        self.screenType = screenType
        self.size = size
        self.deviceName = deviceName
        self.uiOrientation = uiOrientation
        self.scale = scale
    }

    var isExternal: Bool {
        switch screenType {
        case .tvOut, .carPlay: return true
        case .integrated, .unknown: return false
        }
    }

    /// Which of the device's own panels this screen is, if it is one.
    ///
    /// One Integrated screen used to mean one panel. A foldable (iPhone
    /// Duo, iOS 27.1) lists two — the cover as `primary` and the larger
    /// unfolded panel as `primary-1` — and the guest lights one of them
    /// according to the hinge, so "largest integrated" would bind a
    /// black surface half the time. The name says which panel this is;
    /// `HingeAngle.litPanel` says which one to bind.
    var panel: IntegratedPanel? {
        guard screenType == .integrated else { return nil }
        return IntegratedPanel.named(deviceName)
    }
}

/// Pure parser over `xcrun simctl io <udid> enumerate` text.
enum SimctlIOEnumerate {
    static func isCarPlayConnected(_ output: String) -> Bool {
        connectedCarPlay(from: output) != nil
    }

    static func connectedCarPlay(from output: String) -> ConnectedScreenRecord? {
        connectedScreens(from: output).first(where: \.isExternal)
    }

    static func connectedScreens(from output: String) -> [ConnectedScreenRecord] {
        guard let section = connectedScreensSection(in: output) else { return [] }
        var records: [ConnectedScreenRecord] = []
        let pattern = #/(?:^|\n)\s*\((\d+)\)\s+([^:\n]+):\s*\n([\s\S]*?)(?=\n\s*\(\d+\)\s+[^:\n]+:\s*\n|$)/#
        for match in section.matches(of: pattern) {
            let body = String(match.3)
            let fallbackId = UInt32(match.1)
            let headingName = String(match.2).trimmingCharacters(in: .whitespaces)
            let screenId = field(UInt32.self, named: "Screen ID", in: body) ?? fallbackId ?? 0
            let name = field(String.self, named: "Name", in: body) ?? headingName
            let typeRaw = field(String.self, named: "Screen Type", in: body) ?? ""
            let screenType = ConnectedScreenRecord.ScreenType(rawValue: typeRaw) ?? .unknown
            let size = pixelSize(in: body) ?? Size(width: 0, height: 0)
            let deviceName = field(String.self, named: "Device Name", in: body) ?? ""
            let uiOrientation = field(String.self, named: "UI Orientation", in: body)
                .flatMap(orientation(named:))
            records.append(ConnectedScreenRecord(
                screenId: screenId,
                name: name,
                screenType: screenType,
                size: size,
                deviceName: deviceName,
                uiOrientation: uiOrientation,
                scale: field(Double.self, named: "Preferred UI Scale", in: body)
            ))
        }
        return records
    }

    /// The guest's spelling → baguette's device orientation.
    ///
    /// Measured rather than assumed, because UIKit's interface and
    /// device orientations name opposite rotations: a panel the guest
    /// reports as "Landscape Left" holds its status bar along the left
    /// edge of the portrait framebuffer, and reads upright after the
    /// page's `landscape-left` turn (90° clockwise). "Ambiguous" is what
    /// externals and dark panels report, and is no orientation.
    static func orientation(named name: String) -> DeviceOrientation? {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "Portrait": return .portrait
        case "Portrait Upside Down": return .portraitUpsideDown
        case "Landscape Left": return .landscapeLeft
        case "Landscape Right": return .landscapeRight
        default: return nil
        }
    }

    private static func connectedScreensSection(in output: String) -> String? {
        guard let range = output.range(of: "Connected Screens:") else { return nil }
        let after = output[range.upperBound...]
        if let creatable = after.range(of: "Creatable Screen Properties:") {
            return String(after[..<creatable.lowerBound])
        }
        // Stop at the next top-level "Port:" block when present.
        if let port = after.range(of: "\nPort:") {
            return String(after[..<port.lowerBound])
        }
        return String(after)
    }

    private static func field<T: LosslessStringConvertible>(
        _ type: T.Type,
        named name: String,
        in body: String
    ) -> T? {
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: name) + #":\s*(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body)
        else { return nil }
        return T(String(body[range]))
    }

    private static func pixelSize(in body: String) -> Size? {
        guard let raw = field(String.self, named: "Pixel Size", in: body) else { return nil }
        let pattern = #"\{([0-9.]+),\s*([0-9.]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let wRange = Range(match.range(at: 1), in: raw),
              let hRange = Range(match.range(at: 2), in: raw),
              let w = Double(raw[wRange]),
              let h = Double(raw[hRange])
        else { return nil }
        return Size(width: w, height: h)
    }
}
