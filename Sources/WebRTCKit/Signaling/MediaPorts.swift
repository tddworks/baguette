import Foundation

/// The UDP ports a viewer's media may use — what an operator opens in a
/// firewall, or a bench impairs (`baguette serve --webrtc-ports 8190-8194`).
/// `any` lets the system pick an ephemeral port.
public struct MediaPorts: Equatable, Sendable {
    public let range: ClosedRange<UInt16>?

    public static let any = MediaPorts(range: nil)

    public init(_ range: ClosedRange<UInt16>) { self.range = range }
    private init(range: ClosedRange<UInt16>?) { self.range = range }

    /// "8190-8194", or one port "8190"; nil for anything else.
    public init?(parsing written: String) {
        let ends = written.split(separator: "-", omittingEmptySubsequences: false).map { UInt16($0) }
        guard (1...2).contains(ends.count), let low = ends.first ?? nil, let high = ends.last ?? nil,
              low > 0, low <= high
        else { return nil }
        range = low...high
    }

    /// The first port in the range `attempt` binds, in order; the last
    /// refusal when every one is taken. With no range, one attempt at port 0.
    public func bind<T>(_ attempt: (UInt16) throws -> T) throws -> T {
        guard let range else { return try attempt(0) }
        var refusal: (any Error)?
        for port in range {
            do { return try attempt(port) } catch { refusal = error }
        }
        throw refusal!
    }
}
