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
    /// Screen size in 1x points — `mainScreenWidth × mainScreenHeight`
    /// divided by `mainScreenScale`. Used by 9-slice chrome composition
    /// to size the inner canvas area, since DeviceKit's `Screen.pdf` is
    /// a meaningless 1×1 marker. `nil` when any of the three plist keys
    /// is absent.
    let screenSize: Size?

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

        return DeviceProfile(
            chromeIdentifier: bare,
            screenSize: parseScreenSize(dict)
        )
    }

    /// Plist values are NSNumber-bridged; `as? Double` covers integer
    /// and float literals alike. All three keys must be present and the
    /// scale non-zero — anything else returns nil rather than producing
    /// a degenerate size.
    private static func parseScreenSize(_ dict: [String: Any]) -> Size? {
        guard let w = dict["mainScreenWidth"] as? Double,
              let h = dict["mainScreenHeight"] as? Double,
              let s = dict["mainScreenScale"] as? Double,
              s > 0
        else { return nil }
        return Size(width: w / s, height: h / s)
    }
}

enum DeviceProfileParseError: Error, Equatable {
    case malformedPlist
    case missingChromeIdentifier
}
