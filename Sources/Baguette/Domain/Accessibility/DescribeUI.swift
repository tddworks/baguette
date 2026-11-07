import Foundation

/// Which read a caller asked for, from `describe-ui` or a `describe_ui` envelope.
/// The CLI and the wire both parse it here, and neither branches on the case.
enum DescribeUI: Equatable, Sendable {
    /// The whole tree of the screen.
    case screen
    /// What can be done and what the screen says, without the tree.
    case short
    /// The element at one point.
    case point(Point)

    struct Refusal: Error, Equatable {
        let message: String
    }

    /// A short read is of a screen, because the short answer needs one, and a
    /// point needs both coordinates. These are the only refusals.
    static func parse(x: Double?, y: Double?, short: Bool) throws -> DescribeUI {
        switch (x, y) {
        case let (x?, y?):
            guard !short else { throw Refusal(message: "a short read is of the whole screen, so it can't take a point") }
            return .point(Point(x: x, y: y))
        case (nil, nil):
            return short ? .short : .screen
        default:
            throw Refusal(message: "x and y must be supplied together")
        }
    }

    func read(from accessibility: any Accessibility) throws -> AXNode? {
        switch self {
        case .screen, .short: return try accessibility.describeAll()
        case .point(let point): return try accessibility.describeAt(point: point)
        }
    }

    /// The answer for a caller reading it directly.
    func json(of node: AXNode, style: AXAffordance.Style) -> String {
        switch self {
        case .short: return AXAffordance.json(node.agentSummary(style))
        case .screen, .point: return node.json(affordances: style)
        }
    }

    /// The answer's fields, to sit inside a `describe_ui_result` frame.
    func wireFields(of node: AXNode) -> String {
        switch self {
        case .short: return node.agentSummaryFields(.wire)
        case .screen, .point: return #"\#(node.offersFields(.wire)),"tree":\#(node.json)"#
        }
    }
}
