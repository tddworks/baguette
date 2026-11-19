import Foundation

/// Finds the element a caller names. The caller says what it wants, `Search flights`,
/// rather than where it is, and baguette never guesses between several matches.
public enum AXTarget {
    public enum Lookup: Equatable {
        case found(AXNode)
        case ambiguous([AXNode])
        case disabled(AXNode)
        case missing
    }

    public struct Found: Equatable {
        public var lookup: Lookup
        public var screen: AXScreen?
        public var tree: AXNode?

        /// Why a name reached nothing a caller can act on, or `nil` when it reached one
        /// element. It carries the screen, so a caller can correct itself without reading again.
        public func refusal(of name: String) -> Refusal? {
            switch lookup {
            case .found: return nil
            case .ambiguous(let nodes):
                return Refusal(message: "more than one element matches \(name)", matches: nodes.map(\.offerName), screen: tree)
            case .disabled(let node):
                return Refusal(message: "\(node.offerName) is disabled", screen: tree)
            case .missing:
                return Refusal(message: "nothing matches \(name)", screen: tree)
            }
        }

        public init(lookup: Lookup, screen: AXScreen? = nil, tree: AXNode? = nil) {
            self.lookup = lookup
            self.screen = screen
            self.tree = tree
        }
    }

    public struct Refusal: Equatable, Sendable {
        public var message: String
        public var matches: [String] = []
        public var screen: AXNode?

        /// What sits beside `error`: what this screen offers and says, as a success answers.
        public func fields(_ style: AXAffordance.Style = .wire) -> [String: Any] {
            var fields = screen?.agentSummary(style) ?? [:]
            if !matches.isEmpty { fields["matches"] = matches }
            return fields
        }

        public init(message: String, matches: [String] = [], screen: AXNode? = nil) {
            self.message = message
            self.matches = matches
            self.screen = screen
        }
    }

    public static func find(_ name: String, in tree: AXNode) -> Lookup {
        let nodes = candidates(in: tree)
        if let (base, number) = numbered(name), nodes.contains(where: { $0.offerName == base }) {
            let controls = nodes.filter { $0.offerName == base && AXNode.controlRoles.contains($0.role) }
            guard number >= 1, number <= controls.count else { return .missing }
            return verdict(on: controls[number - 1])
        }

        var matches = nodes.filter { $0.offerName == name || $0.label == name || $0.identifier == name }
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
        guard !innermost.isEmpty else { return .missing }

        let controls = innermost.filter { AXNode.controlRoles.contains($0.role) }
        var contenders = controls.isEmpty ? innermost : controls
        if contenders.count > 1 {
            // A page sliding away can still list the same name beside the current one.
            let onScreen = contenders.filter { $0.isVisible(on: tree.screen) }
            if !onScreen.isEmpty { contenders = onScreen }
        }
        guard contenders.count == 1, let chosen = contenders.first else { return .ambiguous(contenders) }
        return verdict(on: chosen)
    }

    /// Waits for the element to appear and be enabled. A cheap glance is tried
    /// first; only the full read sees what the hit-test sweep finds.
    public static func wait(
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
            case .found, .ambiguous: return true
            default: return false
            }
        }
        while true {
            if settled(by: glance()) || settled(by: read()) { return last }
            if now() - start >= timeout { return last }
            sleep(poll)
        }
    }

    private static func verdict(on node: AXNode) -> Lookup {
        node.enabled ? .found(node) : .disabled(node)
    }

    private static func numbered(_ name: String) -> (base: String, number: Int)? {
        guard let hash = name.range(of: " #", options: .backwards), let number = Int(name[hash.upperBound...])
        else { return nil }
        return (String(name[..<hash.lowerBound]), number)
    }

    private static func candidates(in tree: AXNode) -> [AXNode] {
        var out: [AXNode] = []
        func walk(_ node: AXNode) {
            if node.hidden { return }
            if node.role != "AXApplication", node.hasSize { out.append(node) }
            node.children.forEach(walk)
        }
        walk(tree)
        return out
    }
}

public extension AXNode {
    fileprivate func containsAny(of nodes: [AXNode]) -> Bool {
        nodes.contains(self) || children.contains { $0.containsAny(of: nodes) }
    }
}
