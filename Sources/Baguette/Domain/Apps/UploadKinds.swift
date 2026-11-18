import BaguetteDevice
import Foundation

/// What a given upload route will let onto the device.
///
/// Uploads are classified by extension, so a single "put this file on
/// the device" endpoint decides between installing an app and adding a
/// photo *from the bytes*. That's fine for the browser's drag-and-drop
/// affordance, where the user picked the file. It is not fine as a
/// permission boundary: `PluginRoute` derives a plugin's required
/// capability from the **path alone**, deliberately, so that a route
/// nobody mapped is closed rather than silently open.
///
/// Squaring the two means the narrow routes say up front what they
/// accept. `/apps` takes apps, `/media` takes media, and each carries
/// the matching capability; `/files` takes either and is closed to
/// plugins entirely.
struct UploadKinds: OptionSet, Equatable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// An app bundle or a zipped one — `simctl install`.
    static let apps = UploadKinds(rawValue: 1 << 0)
    /// A photo or video — `simctl addmedia`.
    static let media = UploadKinds(rawValue: 1 << 1)

    /// Anything with a home on a simulator. The browser's endpoint.
    static let all: UploadKinds = [.apps, .media]
}
