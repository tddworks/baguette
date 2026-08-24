import Foundation

/// Pure plan for which display plane a stream session binds to.
/// Parsed from the `display` query (`phone`|`carplay`); missing or
/// unknown tokens default to phone. CarPlay plans also request an
/// idempotent enable of the host External Displays panel.
/// A `--display` value no plane answers to. The command surfaces this
/// as a validation error rather than falling back to phone.
enum DisplayFlagError: Error, Equatable {
    case unknown(String)

    var message: String {
        switch self {
        case .unknown(let raw):
            return "--display must be one of: phone, carplay (got \"\(raw)\")"
        }
    }
}

struct StreamDisplayPlan: Equatable, Sendable {
    let kind: DisplayKind
    let enableCarPlay: Bool

    /// Live 3D routes stay on the phone plane regardless of query.
    static let phoneOnly = StreamDisplayPlan(kind: .phone, enableCarPlay: false)

    /// Strict CLI parsing. Unlike the WS query — where an unknown token
    /// quietly means phone — a mistyped `--display` must stop the
    /// invocation, because the caller asked one plane and would silently
    /// get another.
    static func from(cliFlag: String?) throws -> StreamDisplayPlan {
        switch DisplayKind.parse(cliFlag: cliFlag) {
        case .carPlay:
            return StreamDisplayPlan(kind: .carPlay, enableCarPlay: true)
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

    static func from(query: String?) -> StreamDisplayPlan {
        switch DisplayKind.parse(query: query) {
        case .carPlay:
            return StreamDisplayPlan(kind: .carPlay, enableCarPlay: true)
        case .phone, .none:
            return StreamDisplayPlan(kind: .phone, enableCarPlay: false)
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
