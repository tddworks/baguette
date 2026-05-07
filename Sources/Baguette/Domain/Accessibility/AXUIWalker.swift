import Foundation
import CoreGraphics

/// Closure-bag for reading attributes off an opaque accessibility
/// element. Generic over the element type so tests can drive the
/// walker with simple value-type fakes; the production
/// `AXUIElementAccessibility` adapter passes closures backed by
/// `AXUIElementCopyAttributeValue`.
///
/// Mirrors the macOS `kAXAttribute*` family but at the Domain
/// boundary, so no callers know whether the underlying data came
/// from an `AXUIElement`, an `AXPMacPlatformElement`, or a fake.
struct AXUIReader<Element> {
    let role:       (Element) -> String?
    let subrole:    (Element) -> String?
    let label:      (Element) -> String?
    let value:      (Element) -> String?
    let identifier: (Element) -> String?
    let title:      (Element) -> String?
    let help:       (Element) -> String?
    let enabled:    (Element) -> Bool
    let focused:    (Element) -> Bool
    let hidden:     (Element) -> Bool
    let frame:      (Element) -> CGRect
    let children:   (Element) -> [Element]
}

/// Pure tree-walk for the macOS `AXUIElement` hierarchy. Parallel
/// to `AXNode.walk(from:transform:)` for the iOS `AXPMacPlatformElement`
/// path — the iOS walker reads attributes via KVC, this one reads
/// them via injected closures so the production
/// `AXUIElementCopyAttributeValue` calls stay integration-only.
///
/// Frames in the produced `AXNode` tree are translated by
/// `originOffset`: subtract the offset from each frame's origin
/// before emitting. Pass `.zero` to leave frames in screen-global
/// coordinates; pass the target window's origin to get
/// window-relative coordinates that align with a window-cropped
/// screenshot.
///
/// `depthCap` is a defensive bound (real macOS app trees rarely
/// exceed 30 levels; the cap prevents pathological cycles from
/// spinning forever). `deadline` short-circuits child traversal
/// once the wall clock passes — the orchestrator can honour an
/// AX-call deadline without abandoning the partial tree.
enum AXUIWalker {
    static func walk<Element>(
        from root: Element,
        reader: AXUIReader<Element>,
        originOffset: CGPoint = .zero,
        depthCap: Int = 60,
        deadline: Date = .distantFuture
    ) -> AXNode {
        walkInternal(
            element: root,
            depth: 0,
            reader: reader,
            originOffset: originOffset,
            depthCap: depthCap,
            deadline: deadline
        )
    }

    private static func walkInternal<Element>(
        element: Element,
        depth: Int,
        reader: AXUIReader<Element>,
        originOffset: CGPoint,
        depthCap: Int,
        deadline: Date
    ) -> AXNode {
        let role = reader.role(element) ?? "AXUnknown"
        let macFrame = reader.frame(element)
        let projected = CGRect(
            x: macFrame.origin.x - originOffset.x,
            y: macFrame.origin.y - originOffset.y,
            width: macFrame.size.width,
            height: macFrame.size.height
        )

        let children: [AXNode]
        if depth >= depthCap || Date() >= deadline {
            children = []
        } else {
            let kids = reader.children(element)
            children = kids.map {
                walkInternal(
                    element: $0,
                    depth: depth + 1,
                    reader: reader,
                    originOffset: originOffset,
                    depthCap: depthCap,
                    deadline: deadline
                )
            }
        }

        return AXNode(
            role: role,
            subrole:    reader.subrole(element),
            label:      reader.label(element),
            value:      reader.value(element),
            identifier: reader.identifier(element),
            title:      reader.title(element),
            help:       reader.help(element),
            frame: Rect(
                origin: Point(x: Double(projected.origin.x), y: Double(projected.origin.y)),
                size: Size(width: Double(projected.size.width), height: Double(projected.size.height))
            ),
            enabled: reader.enabled(element),
            focused: reader.focused(element),
            hidden:  reader.hidden(element),
            children: children
        )
    }
}
