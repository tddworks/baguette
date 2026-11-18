import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

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

    @Test func `should build a 112-byte orientation message that holds the 108-byte mach message 4-byte aligned`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(data.count == 112)
    }

    @Test func `should head the orientation message with copy-send bits, a 108-byte size and the GSEvent message id`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x00) == 0x13)   // MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)
        #expect(uint32(in: data, at: 0x04) == 108)    // msgh_size
        #expect(uint32(in: data, at: 0x14) == 0x7B)   // msgh_id = GSEventMachMessageID
    }

    @Test func `should leave the destination port empty until PurpleWorkspacePort is patched in`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x08) == 0)
    }

    @Test func `should mark the orientation message as a host-sent device-orientation-changed event`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x18) == (50 | 0x20000))
    }

    @Test func `should size the orientation record at four bytes`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x48) == 4)
    }

    @Test func `should encode portrait as device orientation 1`() {
        let data = OrientationEvent.machMessage(orientation: .portrait)
        #expect(uint32(in: data, at: 0x4C) == 1)
    }

    @Test func `should encode portrait upside down as device orientation 2`() {
        let data = OrientationEvent.machMessage(orientation: .portraitUpsideDown)
        #expect(uint32(in: data, at: 0x4C) == 2)
    }

    @Test func `should encode landscape right as device orientation 3`() {
        let data = OrientationEvent.machMessage(orientation: .landscapeRight)
        #expect(uint32(in: data, at: 0x4C) == 3)
    }

    @Test func `should encode landscape left as device orientation 4`() {
        let data = OrientationEvent.machMessage(orientation: .landscapeLeft)
        #expect(uint32(in: data, at: 0x4C) == 4)
    }

    @Test func `should patch in the destination port without disturbing the rest of the orientation message`() {
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

    @Test func `should look up the PurpleWorkspacePort service by its exact name`() {
        var requestedName: String?
        _ = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { name in requestedName = name; return 0xDEAD_BEEF },
            deliver: { _ in true }
        )
        #expect(requestedName == "PurpleWorkspacePort")
    }

    @Test func `should deliver the full orientation message addressed to the looked-up port`() {
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

    @Test func `should report failure without delivering when no workspace port is found`() {
        var delivered = false
        let ok = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { _ in nil },
            deliver: { _ in delivered = true; return true }
        )
        #expect(!ok)
        #expect(!delivered)
    }

    @Test func `should report failure without delivering when the workspace port is null`() {
        var delivered = false
        let ok = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { _ in 0 },
            deliver: { _ in delivered = true; return true }
        )
        #expect(!ok)
        #expect(!delivered)
    }

    @Test func `should report failure when the port is found but delivery fails`() {
        let ok = OrientationEvent.send(
            orientation: .portrait,
            lookupPort: { _ in 42 },
            deliver: { _ in false }
        )
        #expect(!ok)
    }

    @Test func `should report success when the port is found and delivery succeeds`() {
        let ok = OrientationEvent.send(
            orientation: .portraitUpsideDown,
            lookupPort: { _ in 42 },
            deliver: { _ in true }
        )
        #expect(ok)
    }
}
