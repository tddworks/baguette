import Foundation

/// A simulator screen's input surface: touches, buttons, keys and the
/// wheel all go to one Indigo surface, so one value plays every input
/// role. A simulator's fact, not a device's — other devices register
/// only the roles they have, each on its own.
///
/// A name for the four roles together rather than a protocol: anything
/// that plays them is one, and it asks nothing the roles don't.
typealias HID = Touch & Press & Key & Scroll

extension Abilities {
    /// One screen's input, every role played by the same surface.
    static func input(of device: String, all hid: any HID) -> Abilities {
        .input(of: device, touch: hid, press: hid, key: hid, scroll: hid)
    }
}
