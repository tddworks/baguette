import Testing
import Foundation
import Mockable
@testable import Baguette

/// Unit tests for `SimDeviceLogStream`'s error-path branches.
///
/// Coverage scope: every branch that can be exercised without
/// invoking `xcrun simctl spawn` against a real booted simulator.
/// The successful-spawn path (process runs, lines flow, SIGTERM
/// stops it cleanly) is integration-only — manually smoke-tested
/// via `baguette logs` against a booted iOS sim, not run in CI.
@Suite("SimDeviceLogStream — error paths")
struct SimDeviceLogStreamErrorTests {

    // MARK: - device resolution

    @Test func `start throws simulatorNotBooted when host returns no device`() {
        let host = MockDeviceHost()
        given(host).resolveDevice(udid: .any).willReturn(nil)
        let stream = SimDeviceLogStream(udid: "ghost", host: host)

        #expect(throws: LogStreamError.simulatorNotBooted(udid: "ghost")) {
            try stream.start(filter: LogFilter(), onLine: { _ in }, onTerminate: { _ in })
        }
    }

    @Test func `start throws simulatorNotBooted when device state is shutdown`() {
        let host = MockDeviceHost()
        let device = FakeSimDevice(state: 1) // 1 = shutdown
        given(host).resolveDevice(udid: .any).willReturn(device)
        let stream = SimDeviceLogStream(udid: "u1", host: host)

        #expect(throws: LogStreamError.simulatorNotBooted(udid: "u1")) {
            try stream.start(filter: LogFilter(), onLine: { _ in }, onTerminate: { _ in })
        }
    }

    @Test func `start throws simulatorNotBooted when device state is booting`() {
        let host = MockDeviceHost()
        let device = FakeSimDevice(state: 2) // 2 = booting
        given(host).resolveDevice(udid: .any).willReturn(device)
        let stream = SimDeviceLogStream(udid: "u1", host: host)

        #expect(throws: LogStreamError.simulatorNotBooted(udid: "u1")) {
            try stream.start(filter: LogFilter(), onLine: { _ in }, onTerminate: { _ in })
        }
    }

    // MARK: - lifecycle

    @Test func `stop is idempotent when never started`() {
        let host = MockDeviceHost()
        let stream = SimDeviceLogStream(udid: "u1", host: host)
        // Should not crash, hang, or fire onTerminate.
        stream.stop()
        stream.stop()
    }

    // MARK: - error type contract

    @Test func `LogStreamError equality covers every case`() {
        #expect(LogStreamError.simulatorNotBooted(udid: "u1")
             == LogStreamError.simulatorNotBooted(udid: "u1"))
        #expect(LogStreamError.simulatorNotBooted(udid: "u1")
             != LogStreamError.simulatorNotBooted(udid: "u2"))
        #expect(LogStreamError.spawnFailed(reason: "x")
             == LogStreamError.spawnFailed(reason: "x"))
        #expect(LogStreamError.alreadyStarted == LogStreamError.alreadyStarted)
        #expect(LogStreamError.nonZeroExit(code: 137)
             == LogStreamError.nonZeroExit(code: 137))
        #expect(LogStreamError.alreadyStarted != LogStreamError.simulatorNotBooted(udid: "u1"))
    }
}

// MARK: - Test fakes

/// Minimal NSObject stand-in for a `SimDevice`. Returns the
/// requested integer for `state` (the only KVC key our adapter
/// reads before deciding whether to spawn). Booted = 3.
final class FakeSimDevice: NSObject {
    private let _state: NSNumber

    init(state: UInt) {
        self._state = NSNumber(value: state)
        super.init()
    }

    override func value(forKey key: String) -> Any? {
        switch key {
        case "state": return _state
        default:      return super.value(forKey: key)
        }
    }
}
