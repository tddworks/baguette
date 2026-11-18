import Foundation

/// A set of interface settings to apply. Every field is optional: a
/// caller changes only what it cares about and leaves the rest alone —
/// a panel flipping dark mode shouldn't have to restate the text size
/// it isn't touching.
///
/// The three settings are independent at the simctl level (one spawn
/// each), so this is a request shape rather than a device reading.
/// Nothing here can hold `unknown` or `unsupported`: those are answers a
/// device gives, never instructions it takes, and refusing them at parse
/// time is what turns "echoed a reading back at the server" into a clean
/// `400` instead of a confusing simctl usage dump.
public struct InterfaceUpdate: Equatable, Sendable {
    public var appearance: InterfaceAppearance?
    public var increaseContrast: InterfaceContrast?
    public var contentSize: ContentSizeChange?

    public init(
        appearance: InterfaceAppearance? = nil,
        increaseContrast: InterfaceContrast? = nil,
        contentSize: ContentSizeChange? = nil
    ) {
        self.appearance = appearance
        self.increaseContrast = increaseContrast
        self.contentSize = contentSize
    }

    /// True when the caller asked for nothing. Valid, just a no-op —
    /// distinguishable from a body that failed to parse.
    public var isEmpty: Bool {
        appearance == nil && increaseContrast == nil && contentSize == nil
    }

    /// Parse a wire body. Returns nil when a named field carries a value
    /// that can't be applied, so a bad request never half-applies.
    public static func from(json object: [String: Any]) -> InterfaceUpdate? {
        var update = InterfaceUpdate()

        if let raw = object["appearance"] {
            guard let string = raw as? String else { return nil }
            let parsed = InterfaceAppearance(output: string)
            guard parsed.argument != nil else { return nil }
            update.appearance = parsed
        }

        if let raw = object["increaseContrast"] {
            guard let string = raw as? String else { return nil }
            let parsed = InterfaceContrast(output: string)
            guard parsed.argument != nil else { return nil }
            update.increaseContrast = parsed
        }

        if let raw = object["contentSize"] {
            guard let string = raw as? String,
                  let change = ContentSizeChange(wire: string) else { return nil }
            update.contentSize = change
        }

        return update
    }
}

/// A device's current interface settings — what a read answers.
///
/// Unlike `InterfaceUpdate` this *can* hold `unknown` / `unsupported`,
/// because that's the truthful answer for a device that isn't booted.
public struct InterfaceReading: Equatable, Sendable {
    public let appearance: InterfaceAppearance
    public let increaseContrast: InterfaceContrast
    public let contentSize: ContentSize

    /// Wire projection. Sorted keys so the body is byte-stable.
    public var json: String {
        let dict: [String: Any] = [
            "appearance": appearance.rawValue,
            "increaseContrast": increaseContrast.rawValue,
            "contentSize": contentSize.rawValue,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public init(appearance: InterfaceAppearance, increaseContrast: InterfaceContrast, contentSize: ContentSize) {
        self.appearance = appearance
        self.increaseContrast = increaseContrast
        self.contentSize = contentSize
    }
}
