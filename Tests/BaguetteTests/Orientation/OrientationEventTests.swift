import Foundation
import Testing
@testable import BaguetteCore

/// Wire-format coverage for `OrientationEvent.machMessage(orientation:)`.
/// The bytes-on-the-wire here have to match what
/// GraphicsServices' `_PurpleEventCallback` expects on the iOS side;
/// the format is reverse-engineered from `Simulator.app` and
/// documented at `idb/PrivateHeaders/SimulatorApp/GSEvent.h`.
@Suite("OrientationEvent")
struct OrientationEventTests {

    private func uint32(in data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt32.self)
        }
    }

    @Test func `buffer is 112 bytes (4-byte aligned, holds 108-byte mach message)`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(data.count == 112)
    }

    @Test func `mach header carries COPY_SEND bits, 108-byte size, GSEventMachMessageID`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x00) == 0x13)   // MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)
        #expect(uint32(in: data, at: 0x04) == 108)    // msgh_size
        #expect(uint32(in: data, at: 0x14) == 0x7B)   // msgh_id = GSEventMachMessageID
    }

    @Test func `msgh_remote_port is zero — caller patches in PurpleWorkspacePort`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x08) == 0)
    }

    @Test func `GSEvent type at 0x18 is GSEventTypeDeviceOrientationChanged | GSEventHostFlag`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x18) == (50 | 0x20000))
    }

    @Test func `record_info_size at 0x48 is 4`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x48) == 4)
    }

    @Test func `portrait writes UIDeviceOrientation 1 at 0x4C`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x4C) == 1)
    }

    @Test func `portraitUpsideDown writes UIDeviceOrientation 2 at 0x4C`() {
        let data = OrientationEvent.machMessage(orientation: .portraitUpsideDown)
        #expect(uint32(in: data, at: 0x4C) == 2)
    }

    @Test func `landscapeRight writes UIDeviceOrientation 3 at 0x4C`() {
        let data = OrientationEvent.machMessage(orientation: .landscapeRight)
        #expect(uint32(in: data, at: 0x4C) == 3)
    }

    @Test func `landscapeLeft writes UIDeviceOrientation 4 at 0x4C`() {
        let data = OrientationEvent.machMessage(orientation: .landscapeLeft)
        #expect(uint32(in: data, at: 0x4C) == 4)
    }

    @Test func `patched writes the looked-up port at offset 0x08 without disturbing the body`() {
        let raw = OrientationEvent.machMessage(orientation: .landscapeRight)
        let patched = OrientationEvent.patched(raw, remotePort: 0xCAFE_BEEF)

        #expect(patched.count == raw.count)
        #expect(uint32(in: patched, at: 0x08) == 0xCAFE_BEEF)        // port patched in
        #expect(uint32(in: patched, at: 0x18) == (50 | 0x20000))     // GSEvent type intact
        #expect(uint32(in: patched, at: 0x4C) == 3)                  // payload intact
        #expect(uint32(in: raw, at: 0x08) == 0)                       // input unchanged
    }
}

/// `OrientationEvent.send` is the pure orchestrator: lookup port,
/// build + patch the buffer, hand it off. The two collaborators
/// (`lookupPort`, `deliver`) abstract the irreducible mach IPC so the
/// Domain layer stays free of `mach_msg_header_t` / `kern_return_t`.
@Suite("OrientationEvent.send")
struct OrientationEventSendTests {

    private func uint32(in data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            raw.load(fromByteOffset: offset, as: UInt32.self)
        }
    }

    @Test func `looks up PurpleWorkspacePort by exact service name`() {
        var requestedName: String?
        _ = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { name in requestedName = name; return 0xDEAD_BEEF },
            deliver: { _ in true }
        )
        #expect(requestedName == "PurpleWorkspacePort")
    }

    @Test func `delivers a 112-byte buffer with the looked-up port patched at 0x08 and the orientation payload at 0x4C`() {
        var delivered: Data?
        _ = OrientationEvent.send(
            orientation: .landscapeRight,
            lookupPort: { _ in 0x1234_5678 },
            deliver: { data in delivered = data; return true }
        )
        let buf = try! #require(delivered)
        #expect(buf.count == 112)
        #expect(uint32(in: buf, at: 0x08) == 0x1234_5678)
        #expect(uint32(in: buf, at: 0x18) == (50 | 0x20000))
        #expect(uint32(in: buf, at: 0x4C) == 3)
    }

    @Test func `returns false (without invoking deliver) when lookup yields nil`() {
        var delivered = false
        let ok = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { _ in nil },
            deliver: { _ in delivered = true; return true }
        )
        #expect(!ok)
        #expect(!delivered)
    }

    @Test func `returns false (without invoking deliver) when lookup yields a null port (0)`() {
        var delivered = false
        let ok = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { _ in 0 },
            deliver: { _ in delivered = true; return true }
        )
        #expect(!ok)
        #expect(!delivered)
    }

    @Test func `returns false when lookup succeeds but deliver fails`() {
        let ok = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { _ in 42 },
            deliver: { _ in false }
        )
        #expect(!ok)
    }

    @Test func `returns true when lookup yields a port and deliver succeeds`() {
        let ok = OrientationEvent.send(
            orientation: .portraitUpsideDown,
            lookupPort: { _ in 42 },
            deliver: { _ in true }
        )
        #expect(ok)
    }
}
