import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// A `SimDevice` stand-in that answers `lookup:error:` the way
/// CoreSimulator does for a device that isn't booted: no port, and an
/// `NSError` written back through the out-parameter.
///
/// `error:` is an ObjC `NSError **` — i.e. `__autoreleasing`. The
/// callee hands back a **+0, autoreleased** reference: it belongs to
/// the surrounding autorelease pool, not to the caller. Modelling that
/// faithfully is the whole point of this fake, so `NSErrorPointer`
/// (`AutoreleasingUnsafeMutablePointer<NSError?>?`) is the parameter
/// type — its setter retains + autoreleases exactly as ObjC does.
private final class UnbootedFakeDevice: NSObject {
    let error: NSError
    /// Extra strong references so an over-release on the caller's side
    /// can't drive the error to zero and crash the whole test runner —
    /// it shows up as a retain-count mismatch below instead.
    private let pins: [NSError]

    init(error: NSError) {
        self.error = error
        self.pins = [error, error, error]
        super.init()
    }

    @objc(lookup:error:)
    func lookup(_ name: NSString, error outError: NSErrorPointer) -> UInt32 {
        outError?.pointee = error
        return 0
    }
}

/// Error-path coverage for `PurpleEventOrientation` — the branch a
/// non-booted simulator takes. The happy path (a live
/// `PurpleWorkspacePort` + `mach_msg_send`) is integration-only.
@Suite("PurpleEventOrientation — unbooted device")
struct PurpleEventOrientationTests {

    @Test func `should reject a rotation when the device vends no PurpleWorkspacePort`() {
        let host = MockDeviceHost()
        let device = UnbootedFakeDevice(
            error: NSError(domain: "com.apple.CoreSimulator.SimError", code: 405)
        )
        given(host).resolveDevice(udid: .any).willReturn(device)

        let orientation = PurpleEventOrientation(udid: "unbooted", host: host)

        // Drained while `device` still pins the error: the whole point of
        // the bug below is that the pool holds a reference the adapter
        // must not have consumed.
        let result = autoreleasepool { orientation.set(.portrait) }

        withExtendedLifetime(device) {
            #expect(result == .rejected)
        }
    }

    /// The crash this suite exists for: `serve` segfaulted whenever a
    /// browser tab opened on a non-booted simulator, because the page
    /// POSTs `/orientation?value=portrait` on load. `lookup:error:`
    /// wrote back an autoreleased `NSError`, the adapter released it as
    /// if it owned it, and the process died at the next autorelease-pool
    /// pop — inside an unrelated task, which is why the backtrace
    /// pointed at `objc_autoreleasePoolPop` rather than at orientation.
    ///
    /// Asserted as retain-count parity across a pool drain: the error is
    /// pinned by extra strong references so a double-release shows up as
    /// a failed expectation instead of taking the test runner down with
    /// it.
    @Test func `should not over-release the error CoreSimulator writes back when a rotation fails`() {
        let error = NSError(domain: "com.apple.CoreSimulator.SimError", code: 405)
        let host = MockDeviceHost()
        let device = UnbootedFakeDevice(error: error)
        given(host).resolveDevice(udid: .any).willReturn(device)
        let orientation = PurpleEventOrientation(udid: "unbooted", host: host)

        let before = CFGetRetainCount(error as CFTypeRef)
        autoreleasepool {
            _ = orientation.set(.portrait)
        }
        let after = CFGetRetainCount(error as CFTypeRef)

        withExtendedLifetime(device) {
            #expect(after == before)
        }
    }
}
