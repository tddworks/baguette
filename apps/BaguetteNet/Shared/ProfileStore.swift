import Foundation

/// The one place the host app and the extension agree on a profile:
/// app-group `UserDefaults`. The app writes; the extension reads. Also
/// carries the list of *match keys* (substrings of a flow's
/// `sourceAppIdentifier`) the throttle applies to — empty means "match
/// nothing", the safe default that leaves all traffic alone.
public struct ProfileStore {
    public static let appGroup = "group.com.tddworks.baguette.net"
    private static let profileKey = "network.profile"
    private static let matchKey = "network.matchKeys"

    private let defaults: UserDefaults

    public init?(suiteName: String = ProfileStore.appGroup) {
        guard let d = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = d
    }

    public var profile: NetworkProfile {
        get {
            guard let data = defaults.data(forKey: Self.profileKey),
                  let p = try? JSONDecoder().decode(NetworkProfile.self, from: data)
            else { return .unthrottled }
            return p
        }
        nonmutating set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.profileKey)
        }
    }

    public var matchKeys: [String] {
        get { defaults.stringArray(forKey: Self.matchKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.matchKey) }
    }

    /// True when `sourceAppIdentifier` matches any configured key. Empty
    /// key list → never matches (whole Mac untouched).
    public func matches(sourceAppIdentifier: String?) -> Bool {
        guard let id = sourceAppIdentifier else { return false }
        return matchKeys.contains { !$0.isEmpty && id.localizedCaseInsensitiveContains($0) }
    }
}
