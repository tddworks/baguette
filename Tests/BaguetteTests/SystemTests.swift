import Foundation
import Testing

extension Tag {
    /// A test that drives the real outside world an `Internal/System/` file
    /// wraps — VideoToolbox, a simulator, a socket — rather than a mock.
    @Tag static var system: Self
}

/// Where a system test can run: anywhere but a CI runner, whose encoders
/// and simulators can stall instead of failing. CI runs them in their own
/// job, on a machine that has the real thing.
enum SystemTests {
    static let available = ProcessInfo.processInfo.environment["CI"] == nil
}
