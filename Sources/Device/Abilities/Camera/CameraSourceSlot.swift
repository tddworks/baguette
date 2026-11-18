import Foundation

/// The name of the directory one simulator's uploaded camera source is
/// staged under.
///
/// The udid behind it comes straight off the request path and is
/// percent-decoded before it gets here, so `%2F%2E%2E` arrives as a
/// real `/..` — and the staged directory is handed to a *recursive*
/// removal on every re-upload. A slot therefore only exists for a
/// udid-shaped token: letters, digits, `-` and `_`. Anything else
/// (a separator, a dot, whitespace, a null byte, an empty or absurdly
/// long string) has no slot at all.
///
/// Refusing rather than sanitising is deliberate: stripping the unsafe
/// characters out of two different udids could quietly collapse them
/// onto the same slot, so one simulator's upload would land in
/// another's stream.
public struct CameraSourceSlot: Equatable, Hashable {

    /// Comfortably above a UUID's 36 characters, far below any path cap.
    private static let maxLength = 128

    private static let allowed = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    /// The directory name — safe to append to the staging root, because
    /// it can't contain a separator or a `.` to walk back out with.
    public let name: String

    public init?(udid: String) {
        guard !udid.isEmpty, udid.count <= Self.maxLength else { return nil }
        guard udid.allSatisfy(Self.allowed.contains) else { return nil }
        self.name = udid
    }
}
