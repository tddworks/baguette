import Foundation

/// The simulator's preferred content size category — Dynamic Type.
///
/// Twelve real categories in two ranges: the seven standard sizes a user
/// picks from the text-size slider, and the five **accessibility** sizes
/// behind "Larger Accessibility Sizes". The accessibility range is where
/// layouts actually break, which is why an accessibility audit cares
/// about this at all.
///
/// `settable` is ordered smallest → largest so a UI can render the scale
/// and step along it.
public enum ContentSize: String, Equatable, Sendable, CaseIterable {
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case extraExtraLarge = "extra-extra-large"
    case extraExtraExtraLarge = "extra-extra-extra-large"
    case accessibilityMedium = "accessibility-medium"
    case accessibilityLarge = "accessibility-large"
    case accessibilityExtraLarge = "accessibility-extra-large"
    case accessibilityExtraExtraLarge = "accessibility-extra-extra-large"
    case accessibilityExtraExtraExtraLarge = "accessibility-extra-extra-extra-large"
    /// The runtime or platform has no content size categories.
    case unsupported
    /// Nothing answered — most often the device isn't booted.
    case unknown

    public init(output: String) {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = ContentSize(rawValue: value).flatMap { $0 } ?? .unknown
    }

    /// The twelve real categories, smallest first. Excludes the two
    /// states that can only be read.
    public static let settable: [ContentSize] = allCases.filter { $0.argument != nil }

    /// The token `simctl ui <udid> content_size <arg>` accepts, or nil
    /// for the read-only states.
    public var argument: String? {
        switch self {
        case .unsupported, .unknown: return nil
        default: return rawValue
        }
    }

    /// Whether this is one of the five "Larger Accessibility Sizes" —
    /// the range worth calling out in an audit.
    public var isAccessibilitySize: Bool { rawValue.hasPrefix("accessibility-") }
}

/// How to change the content size.
///
/// Reading answers a category; setting *also* accepts a relative step.
/// Two alphabets, so two types — otherwise a value read back from the
/// device could be handed straight to a setter that rejects it.
public enum ContentSizeChange: Equatable, Sendable {
    case increment
    case decrement
    case size(ContentSize)

    /// Parse the wire / CLI spelling. Nil when it names neither a step
    /// nor a real category — including `unknown`, which is a reading,
    /// not an instruction.
    public init?(wire: String) {
        let value = wire.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "increment": self = .increment
        case "decrement": self = .decrement
        default:
            let size = ContentSize(output: value)
            guard size.argument != nil else { return nil }
            self = .size(size)
        }
    }

    /// How this change spells itself, settable or not. Error messages
    /// need to name what was refused, and a refused change has no
    /// `argument` to name it with.
    public var wire: String {
        switch self {
        case .increment: return "increment"
        case .decrement: return "decrement"
        case .size(let size): return size.rawValue
        }
    }

    /// The token `simctl ui <udid> content_size <arg>` accepts, or nil
    /// when this change wraps a state that can only be read.
    ///
    /// Optional rather than falling back to a real category: `.size(.unknown)`
    /// is constructible in-module, and spelling it `large` would set the
    /// device to a category nobody asked for. Nil lets the setter refuse
    /// it before spawning, exactly as appearance and contrast already do.
    public var argument: String? {
        switch self {
        case .increment, .decrement: return wire
        case .size(let size): return size.argument
        }
    }
}
