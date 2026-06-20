import Foundation
import Mockable

/// Read-only access to a simulator's on-screen UI tree. One instance
/// per simulator. The production adapter routes calls into
/// `AXPTranslator` (private `AccessibilityPlatformTranslation`
/// framework) over XPC into the in-simulator accessibility service —
/// no test-runner / WDA helper required, no host-side AppKit state,
/// so callers don't need to be on the MainActor.
///
/// Both verbs return `nil` when the simulator has nothing focused
/// (no frontmost app, or boot in progress) — that's not an error.
/// Throwing is reserved for unrecoverable failures: framework
/// missing, translator class absent, XPC handshake failed.
@Mockable
protocol Accessibility: AnyObject, Sendable {
    /// Snapshot of the frontmost application's accessibility tree.
    /// Returns `nil` when no app is focused (e.g. SpringBoard idle).
    func describeAll() throws -> AXNode?

    /// Hit-test the topmost accessibility element at `point`
    /// (device-point coordinates, same units as gesture wire input).
    /// Returns `nil` when the point falls outside any accessible
    /// element. The returned node has its `children` populated
    /// shallowly (one level) so a downstream agent can introspect
    /// without an extra round-trip.
    func describeAt(point: Point) throws -> AXNode?
}
