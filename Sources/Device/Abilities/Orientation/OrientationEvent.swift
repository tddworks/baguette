import Foundation

/// Pure builder for the `PurpleWorkspacePort` mach message that tells a
/// booted iOS its orientation has changed. The wire format below is
/// reverse-engineered from `Simulator.app`'s
/// `[SimDevice(GSEvents) gsEventsSendOrientation:]`; idb's
/// `PrivateHeaders/SimulatorApp/GSEvent.h` documents the same bytes.
///
/// Layout (all little-endian, total backing buffer 112 bytes,
/// `msgh_size` = 108 = align4(record_info_size + 0x6B)):
///
/// ```
/// 0x00  msgh_bits          = 0x13 (MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0))
/// 0x04  msgh_size          = 108
/// 0x08  msgh_remote_port   = 0      (caller patches with PurpleWorkspacePort)
/// 0x14  msgh_id            = 0x7B   (GSEventMachMessageID)
/// 0x18  GSEvent.type       = 50 | 0x20000 (GSEventTypeDeviceOrientationChanged | GSEventHostFlag)
/// 0x48  record_info_size   = 4
/// 0x4C  record_info_data   = UIDeviceOrientation raw value (1..4)
/// ```
///
/// The Infrastructure adapter looks up the port via `SimDevice.lookup`,
/// patches `msgh_remote_port` at offset 0x08, and `mach_msg_send`s the
/// header. Everything below the dotted line is just a pure byte layout
/// — kept here so it can be unit-tested without touching mach IPC.
public enum OrientationEvent {

    /// Build a 112-byte buffer for `mach_msg_send` to
    /// `PurpleWorkspacePort`. Caller MUST overwrite bytes 0x08..0x0B
    /// with the looked-up port before sending; otherwise the kernel
    /// drops the message with `KERN_INVALID_DEST`.
    public static func machMessage(orientation: DeviceOrientation) -> Data {
        var bytes = [UInt8](repeating: 0, count: 112)
        // mach_msg_header_t (24 bytes).
        write(0x13,                       at: 0x00, into: &bytes)  // msgh_bits
        write(108,                        at: 0x04, into: &bytes)  // msgh_size
        // 0x08 msgh_remote_port — left zero, patched by caller.
        // 0x0C msgh_local_port, 0x10 msgh_voucher_port — both zero.
        write(0x7B,                       at: 0x14, into: &bytes)  // msgh_id

        // GSEvent body.
        write(50 | 0x20000,               at: 0x18, into: &bytes)  // GSEvent.type
        // 0x1C subtype, 0x20..0x47 zeroed location/timestamp fields.
        write(4,                          at: 0x48, into: &bytes)  // record_info_size
        write(orientation.rawValue,       at: 0x4C, into: &bytes)  // record_info_data
        return Data(bytes)
    }

    /// Patch the looked-up `PurpleWorkspacePort` into a buffer
    /// produced by `machMessage(orientation:)`. Pulled out so the
    /// patch step itself is unit-testable without `mach_port_t`.
    public static func patched(_ data: Data, remotePort: UInt32) -> Data {
        var copy = data
        write(remotePort, at: 0x08, into: &copy)
        return copy
    }

    /// Drive the full GSEvent send: look up the `PurpleWorkspacePort`
    /// in the simulator's bootstrap namespace, patch the buffer, and
    /// hand it to `deliver` for `mach_msg_send`. The two callbacks
    /// abstract the irreducible system calls so this orchestrator
    /// stays in Domain (no Darwin.Mach types leak in); the
    /// Infrastructure adapter wraps `SimDevice.lookup(_:error:)` and
    /// `mach_msg_send` to satisfy them.
    ///
    /// Returns `false` (without invoking `deliver`) when the port
    /// lookup yields `nil` or `0` — both mean "the simulator hasn't
    /// vended a PurpleWorkspacePort yet" (e.g. not booted, or booted
    /// but pre-springboard). Otherwise returns whatever `deliver`
    /// returns.
    public static func send(
        orientation: DeviceOrientation,
        lookupPort: (String) -> UInt32?,
        deliver: (Data) -> Bool
    ) -> Bool {
        guard let port = lookupPort("PurpleWorkspacePort"), port != 0 else {
            return false
        }
        let buffer = patched(machMessage(orientation: orientation), remotePort: port)
        return deliver(buffer)
    }

    private static func write(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { src in
            for i in 0..<4 { bytes[offset + i] = src[i] }
        }
    }

    private static func write(_ value: UInt32, at offset: Int, into data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { src in
            for i in 0..<4 { data[offset + i] = src[i] }
        }
    }
}
