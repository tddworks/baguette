import Foundation

/// What we read from a CoreSimulator device-type's `profile.plist`.
/// Today we only need the `chromeIdentifier` to find the matching
/// DeviceKit chrome bundle, so the value carries just that — keeps
/// the type honest. New fields (e.g. `mainScreenScale`) get added the
/// moment a caller actually needs them.
struct DeviceProfile: Equatable, Sendable {
    /// Bare bundle name like `"phone11"` or `"tablet5"`. The plist
    /// stores the full bundle id (`com.apple.dt.devicekit.chrome.phone11`);
    /// we strip the prefix at parse time so the rest of the system
    /// works in directory-name space.
    let chromeIdentifier: String

    static func parsing(plistData data: Data) throws -> DeviceProfile {
        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            )
        } catch {
            throw DeviceProfileParseError.malformedPlist
        }
        guard let dict = raw as? [String: Any] else {
            throw DeviceProfileParseError.malformedPlist
        }
        guard let fullID = dict["chromeIdentifier"] as? String else {
            throw DeviceProfileParseError.missingChromeIdentifier
        }

        let prefix = "com.apple.dt.devicekit.chrome."
        let bare = fullID.hasPrefix(prefix)
            ? String(fullID.dropFirst(prefix.count))
            : fullID

        return DeviceProfile(chromeIdentifier: bare)
    }
}

enum DeviceProfileParseError: Error, Equatable {
    case malformedPlist
    case missingChromeIdentifier
}
