import Foundation

/// The grid of screen points at which the AX adapter runs
/// accessibility hit-tests (`accessibilityHitTest` / AXP's
/// `objectAtPoint:displayId:bridgeDelegateToken:`) to recover elements
/// the recursive tree walk can't reach.
///
/// The frontmost-app tree walk (`frontmostApplicationWithDisplayId:`
/// → recurse `accessibilityChildren`) is *process-scoped*: it can
/// only ever see the foreground app's hierarchy. Two important kinds
/// of element fall outside it:
///
///   - **SpringBoard's status bar** — the clock, Wi-Fi, cellular and
///     battery glyphs are rendered by a *different process*, so they
///     are never in the frontmost app's tree.
///   - **Childless SwiftUI containers** — tab bars, nav bars and
///     toolbars routinely report an empty `accessibilityChildren`
///     yet still answer positional hit-tests.
///
/// Both are recoverable with a *position-scoped* hit-test, which
/// resolves whatever element owns a pixel regardless of process. This
/// type produces the device-point coordinates the adapter hit-tests.
///
/// Points are emitted **row-major from the top** so the status-bar
/// strip is hit-tested first — even if the per-call XPC deadline cuts
/// the sweep short, the status bar is already captured. Points inside
/// a `covered` rect are dropped (the walk already fully described
/// those elements, so re-hitting them only costs a redundant XPC),
/// and the total is capped so a large screen can't explode the
/// hit-test count.
struct AXHitTestGrid: Equatable, Sendable {
    let size: Size
    let step: Double
    let cap: Int

    init(size: Size, step: Double = 32, cap: Int = 600) {
        self.size = size
        self.step = step
        self.cap = cap
    }

    /// Cell-centred grid points (offset half a step from the top-left
    /// so samples land in cell interiors rather than on element
    /// borders), row-major from the top, dropping any point inside a
    /// `covered` rect and truncating to `cap`.
    func samplePoints(covered: [Rect] = []) -> [Point] {
        guard size.width > 0, size.height > 0, step > 0 else { return [] }
        var points: [Point] = []
        var y = step / 2
        while y < size.height {
            var x = step / 2
            while x < size.width {
                let p = Point(x: x, y: y)
                if !covered.contains(where: { Self.contains($0, p) }) {
                    points.append(p)
                    if points.count >= cap { return points }
                }
                x += step
            }
            y += step
        }
        return points
    }

    /// Half-open containment (`[origin, origin + size)`), matching the
    /// convention `AXNode.hitTest` and `CGRect` use.
    private static func contains(_ r: Rect, _ p: Point) -> Bool {
        let minX = r.origin.x, minY = r.origin.y
        let maxX = minX + r.size.width, maxY = minY + r.size.height
        return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }
}
