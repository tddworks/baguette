import Foundation

/// Pure plan for which display plane a stream session binds to.
/// Parsed from the `display` query (`phone`|`carplay`); missing or
/// unknown tokens default to phone. CarPlay plans also request an
/// idempotent enable of the host External Displays panel.
/// A `--display` value no plane answers to. The command surfaces this
/// as a validation error rather than falling back to phone.
public enum DisplayFlagError: Error, Equatable {
    case unknown(String)
    case invalidExistingDisplay

    public var message: String {
        switch self {
        case .unknown(let raw):
            return "--display must be one of: phone, carplay (got \"\(raw)\")"
        case .invalidExistingDisplay:
            return "requireExistingDisplay must be a single 0 or 1"
        }
    }
}

public struct StreamDisplayPlan: Equatable, Sendable {
    public let kind: DisplayKind
    public let enableCarPlay: Bool
    /// The phone plane pinned to one of a foldable's panels, or `nil`
    /// to follow the hinge. Only meaningful for `.phone`.
    public let panel: IntegratedPanel?

    public init(kind: DisplayKind, enableCarPlay: Bool, panel: IntegratedPanel? = nil) {
        self.kind = kind
        self.enableCarPlay = enableCarPlay
        self.panel = kind == .phone ? panel : nil
    }

    /// Live 3D routes stay on the phone plane regardless of query.
    public static let phoneOnly = StreamDisplayPlan(kind: .phone, enableCarPlay: false)

    /// Strict CLI parsing. Unlike the WS query — where an unknown token
    /// quietly means phone — a mistyped `--display` must stop the
    /// invocation, because the caller asked one plane and would silently
    /// get another.
    ///
    /// `requireExistingDisplay` keeps a CarPlay plan from enabling the
    /// host External Displays panel: the caller wants the display that
    /// is already attached, and an absent one must fail instead of
    /// appearing because the stream asked for it.
    public static func from(cliFlag: String?, requireExistingDisplay: Bool = false) throws -> StreamDisplayPlan {
        switch DisplayKind.parse(cliFlag: cliFlag) {
        case .carPlay:
            return StreamDisplayPlan(kind: .carPlay, enableCarPlay: !requireExistingDisplay)
        case .phone:
            return StreamDisplayPlan(kind: .phone, enableCarPlay: false)
        case .none:
            // Present-but-unparseable is rejected whatever it holds,
            // empty included: `--display "$PLANE"` with nothing in
            // `$PLANE` would otherwise take the phone silently, which is
            // the one outcome this parser exists to rule out. Only an
            // absent flag means phone.
            if let raw = cliFlag {
                throw DisplayFlagError.unknown(raw)
            }
            return StreamDisplayPlan(kind: .phone, enableCarPlay: false)
        }
    }

    /// `panel` is the stream route's `?panel=primary|secondary`; anything
    /// else leaves the plane to the hinge.
    public static func from(query: String?, panel: String? = nil, requireExistingDisplay: Bool = false) -> StreamDisplayPlan {
        let pinned: IntegratedPanel?
        switch panel {
        case "primary": pinned = .primary
        case "secondary": pinned = .secondary
        default: pinned = nil
        }
        switch DisplayKind.parse(query: query) {
        case .carPlay:
            return StreamDisplayPlan(kind: .carPlay, enableCarPlay: !requireExistingDisplay)
        case .phone, .none:
            return StreamDisplayPlan(kind: .phone, enableCarPlay: false, panel: pinned)
        }
    }

    /// The stream route's `?requireExistingDisplay=` values. Strict, unlike
    /// `display`: a typo here would silently attach a display the caller
    /// asked never to attach, so anything but one `0` or `1` is rejected.
    public static func requireExistingDisplay(query: [String]) throws -> Bool {
        guard query.count <= 1 else { throw DisplayFlagError.invalidExistingDisplay }
        guard let value = query.first else { return false }
        switch value {
        case "0": return false
        case "1": return true
        default: throw DisplayFlagError.invalidExistingDisplay
        }
    }

}

public extension StreamDisplayPlan {
    /// The planned plane's screen on any device. The phone plane is the
    /// device's own `screen` unless a panel is pinned; a pinned panel and
    /// CarPlay come from its `displays`, which only a simulator registers.
    /// CarPlay fails closed, as `bind(to:)` does.
    func screen(on device: any Device) throws -> any Screen {
        try plane(on: device)?.screen() ?? device.require(.screen)
    }

    /// The planned plane's input on any device, chosen as `screen(on:)` is:
    /// a plane's own surface, or the device's input abilities — each made
    /// once, so a finger lifts where it went down. Refused when the device
    /// has nothing to touch or isn't running.
    func input(on device: any Device) throws -> Abilities {
        if let plane = try plane(on: device) {
            return .input(of: device.name, all: plane.input())
        }
        return try device.input()
    }

    /// The planned plane's screen and input on any device, the plane
    /// resolved once — so CarPlay is enabled once, and the screen and the
    /// input share one binding. A device that shows a screen but takes no
    /// touches still streams: its input is nil.
    func bind(to device: any Device) throws -> (screen: any Screen, input: Abilities?) {
        if let plane = try plane(on: device) {
            return (plane.screen(), .input(of: device.name, all: plane.input()))
        }
        return (try device.require(.screen), try? device.input())
    }

    /// The display a pinned panel or CarPlay names; nil for the device's
    /// own screen.
    private func plane(on device: any Device) throws -> (any Display)? {
        if enableCarPlay {
            try device.require(.externalDisplays).enableCarPlay()
        }
        switch kind {
        case .phone:
            guard let panel else { return nil }
            return try device.require(.displays).panel(panel)
        case .carPlay:
            let display = try device.require(.displays).carPlay
            _ = try display.resolve()
            return display
        }
    }
}
