import Foundation

/// The screen-reading role of a device that never registered one, for a
/// session that must hold one (`baguette input`): each call answers with
/// the device's refusal, so a describe or fill line reports why, while the
/// session's gestures go on. It reads nothing and pretends nothing.
public final class UnableAccessibility: Accessibility, @unchecked Sendable {
    private let refusal: DeviceError

    public init(_ refusal: DeviceError) {
        self.refusal = refusal
    }

    public func describeAll() throws -> AXNode? { throw refusal }
    public func glance() throws -> AXNode? { throw refusal }
    public func wake() throws { throw refusal }
    public func press(_ node: AXNode) throws -> Bool { throw refusal }
    public func describeAt(point: Point) throws -> AXNode? { throw refusal }
}
