import Foundation

/// Finds the element a caller names and a point on it to tap.
///
/// The caller says what it wants, `Search flights`, rather than where it is.
/// That saves a read before a click, and the arithmetic that goes wrong: a
/// frame's centre can hang off the screen, or be blank space on a row with a
/// name at one end and a price at the other.
enum AXTarget {
    enum Lookup: Equatable {
        case tap(AXNode, Point)
        case ambiguous([AXNode])
        case disabled(AXNode)
        case offScreen(AXNode)
        case covered(AXNode)
        case missing
    }

    struct Found: Equatable {
        var lookup: Lookup
        var screen: AXScreen?
        var tree: AXNode?
    }

    static func find(_ name: String, in tree: AXNode) -> Lookup {
        let nodes = candidates(in: tree)
        var matches = nodes.filter { $0.label == name || $0.identifier == name }
        if matches.isEmpty {
            matches = nodes.filter {
                ($0.label ?? "").localizedCaseInsensitiveContains(name)
                    || ($0.identifier ?? "").localizedCaseInsensitiveContains(name)
            }
        }
        // A container that shares its child's name isn't what was meant.
        let innermost = matches.filter { match in
            !match.children.contains { $0.containsAny(of: matches) }
        }
        guard let first = innermost.first else { return .missing }

        let bounds = tree.screen.map {
            Rect(origin: Point(x: 0, y: 0), size: Size(width: $0.width, height: $0.height))
        }
        let visible = innermost.filter { $0.visibleFrame(in: bounds) != nil }
        guard !visible.isEmpty else { return .offScreen(first) }

        let controls = visible.filter { AXNode.controlRoles.contains($0.role) }
        let contenders = controls.isEmpty ? visible : controls
        guard contenders.count == 1, let chosen = contenders.first else { return .ambiguous(contenders) }
        guard chosen.enabled else { return .disabled(chosen) }
        if let screen = tree.screen, tree.isCovered(chosen, on: screen) { return .covered(chosen) }
        return .tap(chosen, tapPoint(on: chosen, bounds: bounds))
    }

    /// The names on screen, so a caller with a wrong name can correct it.
    static func visibleNames(in tree: AXNode) -> [String] {
        let bounds = tree.screen.map {
            Rect(origin: Point(x: 0, y: 0), size: Size(width: $0.width, height: $0.height))
        }
        var seen = Set<String>()
        return candidates(in: tree).compactMap { node in
            guard let label = node.label, !label.trimmingCharacters(in: .whitespaces).isEmpty,
                node.visibleFrame(in: bounds) != nil, seen.insert(label).inserted
            else { return nil }
            return label
        }
    }

    /// Waits for the element to appear and be enabled. A cheap glance is
    /// tried first; only the full read sees what the hit-test sweep finds.
    static func wait(
        for name: String,
        glance: () -> AXNode?,
        read: () -> AXNode?,
        timeout: TimeInterval = 5,
        poll: TimeInterval = 0.1,
        now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Found {
        let start = now()
        var last = Found(lookup: .missing)
        func settled(by tree: AXNode?) -> Bool {
            guard let tree else { return false }
            let lookup = find(name, in: tree)
            if lookup != .missing || last.tree == nil {
                last = Found(lookup: lookup, screen: tree.screen, tree: tree)
            }
            switch lookup {
            case .tap, .ambiguous: return true
            default: return false
            }
        }
        while true {
            if settled(by: glance()) || settled(by: read()) { return last }
            if now() - start >= timeout { return last }
            sleep(poll)
        }
    }

    private static func candidates(in tree: AXNode) -> [AXNode] {
        var out: [AXNode] = []
        func walk(_ node: AXNode) {
            if node.hidden { return }
            if node.role != "AXApplication", node.frame.size.width > 0, node.frame.size.height > 0 {
                out.append(node)
            }
            node.children.forEach(walk)
        }
        walk(tree)
        return out
    }

    private static func tapPoint(on node: AXNode, bounds: Rect?) -> Point {
        node.tapPoint(in: node.visibleFrame(in: bounds) ?? node.frame)
    }
}

extension AXNode {
    fileprivate func containsAny(of nodes: [AXNode]) -> Bool {
        nodes.contains(self) || children.contains { $0.containsAny(of: nodes) }
    }

    /// The part of `frame` on screen, or `nil` when none of it is.
    fileprivate func visibleFrame(in bounds: Rect?) -> Rect? {
        guard let bounds else { return frame }
        let minX = max(frame.origin.x, bounds.origin.x)
        let minY = max(frame.origin.y, bounds.origin.y)
        let maxX = min(frame.origin.x + frame.size.width, bounds.origin.x + bounds.size.width)
        let maxY = min(frame.origin.y + frame.size.height, bounds.origin.y + bounds.size.height)
        guard maxX > minX, maxY > minY else { return nil }
        return Rect(origin: Point(x: minX, y: minY), size: Size(width: maxX - minX, height: maxY - minY))
    }
}
