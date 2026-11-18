import BaguetteDevice
import Foundation

/// The extra screens a simulator can show beside its own glass: the
/// CarPlay external display it can drive, and the Apple Watch paired
/// with it.
///
/// Availability is the point. The focus-mode rail offers a screen that
/// is there and explains one that isn't, so "absent" is an answer this
/// type carries rather than an error the caller has to interpret — a
/// device with neither is the common case, not a failure.
struct CompanionScreens: Sendable, Equatable {
    /// The size of the external display that actually bound, if one did.
    ///
    /// Deliberately not "is CarPlay connected". The plane binds *the
    /// best external display* — `DisplayKind.carPlay` names the plane,
    /// not what the host attached to it, and the External Displays menu
    /// can attach a TVOut of some other resolution just as easily.
    /// Labelling that "CarPlay" in the UI promises something the pane
    /// isn't showing, so the size travels instead and the rail says what
    /// is really there.
    let externalSize: Size?
    let watch: PairedWatch?

    var json: String {
        var watchField: [String: Any] = ["available": watch != nil]
        if let watch {
            watchField["udid"] = watch.udid
            watchField["name"] = watch.name
            // The rail asks only whether the watch is booted, in simctl's word.
            watchField["state"] = watch.state == .ready ? "Booted"
                : watch.state == .starting ? "Booting" : "Shutdown"
        }
        var externalField: [String: Any] = ["available": externalSize != nil]
        if let externalSize {
            externalField["width"] = externalSize.width
            externalField["height"] = externalSize.height
        }
        let dict: [String: Any] = [
            "external": externalField,
            "watch": watchField,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data(#"{"external":{"available":false},"watch":{"available":false}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
