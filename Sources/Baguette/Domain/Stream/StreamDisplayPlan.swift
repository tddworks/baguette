import Foundation

/// Pure plan for which display plane a stream session binds to.
/// Parsed from the `display` query (`phone`|`carplay`); missing or
/// unknown tokens default to phone. CarPlay plans also request an
/// idempotent enable of the host External Displays panel.
/// A `--display` value no plane answers to. The command surfaces this
/// as a validation error rather than falling back to phone.
enum DisplayFlagError: Error, Equatable {
    case unknown(String)
    case invalidExistingDisplay

    var message: String {
        switch self {
        case .unknown(let raw):
            return "--display must be one of: phone, carplay (got \"\(raw)\")"
        case .invalidExistingDisplay:
            return "requireExistingDisplay must be a single 0 or 1"
        }
    }
}

struct StreamDisplayPlan: Equatable, Sendable {
    let kind: DisplayKind
    let enableCarPlay: Bool
    /// The phone plane pinned to one of a foldable's panels, or `nil`
    /// to follow the hinge. Only meaningful for `.phone`.
    let panel: IntegratedPanel?

    init(kind: DisplayKind, enableCarPlay: Bool, panel: IntegratedPanel? = nil) {
        self.kind = kind
        self.enableCarPlay = enableCarPlay
        self.panel = kind == .phone ? panel : nil
    }

    /// Live 3D routes stay on the phone plane regardless of query.
    static let phoneOnly = StreamDisplayPlan(kind: .phone, enableCarPlay: false)

    /// Strict CLI parsing. Unlike the WS query — where an unknown token
    /// quietly means phone — a mistyped `--display` must stop the
    /// invocation, because the caller asked one plane and would silently
    /// get another.
    ///
    /// `requireExistingDisplay` keeps a CarPlay plan from enabling the
    /// host External Displays panel: the caller wants the display that
    /// is already attached, and an absent one must fail instead of
    /// appearing because the stream asked for it.
    static func from(cliFlag: String?, requireExistingDisplay: Bool = false) throws -> StreamDisplayPlan {
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
    static func from(query: String?, panel: String? = nil, requireExistingDisplay: Bool = false) -> StreamDisplayPlan {
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
    static func requireExistingDisplay(query: [String]) throws -> Bool {
        guard query.count <= 1 else { throw DisplayFlagError.invalidExistingDisplay }
        guard let value = query.first else { return false }
        switch value {
        case "0": return false
        case "1": return true
        default: throw DisplayFlagError.invalidExistingDisplay
        }
    }

    /// Enables CarPlay when asked, then returns screen + input for the
    /// planned plane. Phone keeps the legacy `Simulator.screen` /
    /// `input` aliases; CarPlay takes both from the `displays`
    /// aggregate so framebuffer and HID share one binding.
    func bind(to sim: Simulator) throws -> (screen: any Screen, input: any Input) {
        if enableCarPlay {
            try sim.externalDisplays().enableCarPlay()
        }
        switch kind {
        case .phone:
            if let panel {
                let display = sim.displays().panel(panel)
                return (display.screen(), display.input())
            }
            return (sim.screen(), sim.input())
        case .carPlay:
            let display = sim.displays()[.carPlay]
            // Fail closed: never open an unbound Screen that would
            // silently stream the phone plane into the CarPlay pane.
            _ = try display.resolve()
            return (display.screen(), display.input())
        }
    }
}
