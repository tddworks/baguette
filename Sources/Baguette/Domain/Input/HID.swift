import Foundation

/// One surface that plays every input role — touches, buttons, keys and
/// the wheel. A simulator's display plane is one (its Indigo surface);
/// other devices register only the roles they have, each on its own.
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
