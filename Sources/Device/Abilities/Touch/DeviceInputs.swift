import Foundation

/// Each running device's input, made once and kept for the next gesture
/// posted to it (`POST …/input`). Making a simulator's input opens a HID
/// connection, ~300 ms before its first touch lands; a socket keeps its own
/// input for its life, and so does this, per device, across requests. Seen
/// not running, a device's kept input is dropped, so once it runs again
/// (a reboot) it gets a fresh one.
public final class DeviceInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [DeviceID: Abilities] = [:]

    public init() {}

    /// `device`'s input: the kept one, or one made now. Refused, as
    /// `Device.input()` refuses, when it has nothing to touch or isn't running.
    public func input(of device: any Device) throws -> Abilities {
        let id = device.id
        let state = device.state
        guard state.canAcceptInput else {
            lock.withLock { kept[id] = nil }
            throw DeviceError.notReady(device: device.name, state: state)
        }
        if let input = lock.withLock({ kept[id] }) { return input }
        let input = try device.input()
        return lock.withLock {
            if let raced = kept[id] { return raced }
            kept[id] = input
            return input
        }
    }
}
