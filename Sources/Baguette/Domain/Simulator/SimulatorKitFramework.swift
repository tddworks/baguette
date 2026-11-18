import BaguetteDevice
import Foundation

/// Where `SimulatorKit.framework` lives inside an Xcode install.
///
/// Xcode ≤26 ships it under the developer directory, in
/// `Contents/Developer/Library/PrivateFrameworks/`. Xcode 27 moved it
/// up a level into `Contents/SharedFrameworks/` — a *sibling* of
/// `Contents/Developer`, so it can no longer be reached by appending to
/// the path `xcode-select -p` reports. Baguette hardcoded the old
/// location at every `dlopen` site, which is why a machine whose only
/// Xcode is 27 can't drive a simulator at all (issue #28).
///
/// Both layouts are probed here, oldest-first, so an Xcode 26 install
/// resolves to exactly the path it always did.
enum SimulatorKitFramework {

    private static let suffix = "SimulatorKit.framework/SimulatorKit"

    /// Every location SimulatorKit is known to occupy, in probe order.
    ///
    /// Exposed separately from `path(developerDir:exists:)` so failure
    /// diagnostics can list what was actually searched rather than
    /// echoing a single path the user never had.
    static func candidatePaths(developerDir: String) -> [String] {
        // `Contents/Developer` → `Contents`. Resolved by trimming rather
        // than by appending `..` so the path that reaches a log message
        // is the one a user can paste into `ls`.
        let contents = (developerDir as NSString).deletingLastPathComponent
        return [
            (developerDir as NSString)
                .appendingPathComponent("Library/PrivateFrameworks/\(suffix)"),
            (contents as NSString)
                .appendingPathComponent("SharedFrameworks/\(suffix)"),
        ]
    }

    /// The first known location that exists, or `nil` when this Xcode
    /// carries no SimulatorKit at all.
    ///
    /// `exists` is injected so resolution order is unit-provable without
    /// either Xcode version installed.
    static func path(
        developerDir: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        candidatePaths(developerDir: developerDir).first(where: exists)
    }
}
