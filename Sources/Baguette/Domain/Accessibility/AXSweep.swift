import Foundation

/// Decides where the hit-test sweep looks, and when it can stop.
///
/// A hit-test costs an XPC round-trip, and most of the screen was already
/// described by the walk, so the sweep looks in three stages:
///
///   1. **Always:** the status strip and the childless containers
///      (`AXNode.unseenRegions`), where the walk structurally can't see.
///   2. **Scouts:** a coarse grid over the gaps between known elements.
///   3. **In full:** the fine grid over those gaps, but only when a scout
///      found something the walk didn't know. Web content is the case:
///      it lives in another process, so the walk doesn't report it at all.
///
/// A walk that found nothing gets the fine grid everywhere.
enum AXSweep {
    struct Result: Equatable {
        var discovered: [AXNode] = []
        var probed = 0
    }

    static func run(
        base: AXNode,
        fine: AXHitTestGrid,
        scout: AXHitTestGrid,
        statusStrip: Rect,
        keepGoing: () -> Bool,
        probe: (Point) -> AXNode?
    ) -> Result {
        var result = Result()
        var known = Set<String>()
        collectKeys(of: base, into: &known)
        var foundNew = false

        func look(at points: [Point]) {
            for point in points {
                guard keepGoing() else { return }
                result.probed += 1
                guard let node = probe(point) else { continue }
                result.discovered.append(node)
                if node.saysSomething, known.insert(node.dedupKey).inserted { foundNew = true }
            }
        }

        if base.children.isEmpty {
            look(at: fine.samplePoints())
            return result
        }

        let regions = base.unseenRegions() + [statusStrip]
        look(at: fine.samplePoints(within: regions))

        // What the first look found is known now: only a scout's own
        // discovery says the gaps hide something.
        foundNew = false
        let described = base.contentLeafFrames() + regions
        look(at: scout.samplePoints(covered: described))
        if foundNew { look(at: fine.samplePoints(covered: described)) }
        return result
    }

    private static func collectKeys(of node: AXNode, into keys: inout Set<String>) {
        keys.insert(node.dedupKey)
        for child in node.children { collectKeys(of: child, into: &keys) }
    }
}

extension AXNode {
    /// A hit worth treating as a discovery; a bare container only says the
    /// point belongs to some group.
    fileprivate var saysSomething: Bool {
        isContentLeaf || !(label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || !(value ?? "").isEmpty
    }
}
