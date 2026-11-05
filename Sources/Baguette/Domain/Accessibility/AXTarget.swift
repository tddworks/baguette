import Foundation

/// Finds the element a caller names. The caller says what it wants, `Search flights`,
/// rather than where it is, and baguette never guesses between several matches.
enum AXTarget {
    enum Lookup: Equatable {
        case found(AXNode)
        case ambiguous([AXNode])
        case disabled(AXNode)
        case missing
    }

    struct Found: Equatable {
        var lookup: Lookup
        var screen: AXScreen?
        var tree: AXNode?
    }

    static func find(_ name: String, in tree: AXNode) -> Lookup {
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

    /// The names on screen, so a caller with a wrong name can correct it.
    static func visibleNames(in tree: AXNode) -> [String] {
        var seen = Set<String>()
        return candidates(in: tree).compactMap { node in
            guard node.label != nil, node.isVisible(on: tree.screen), seen.insert(node.offerName).inserted
            else { return nil }
            return node.offerName
        }
    }

    /// Waits for the element to appear and be enabled. A cheap glance is tried
    /// first; only the full read sees what the hit-test sweep finds.
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

extension AXNode {
    fileprivate func containsAny(of nodes: [AXNode]) -> Bool {
        nodes.contains(self) || children.contains { $0.containsAny(of: nodes) }
    }
}
