import BaguetteDevice
import Foundation

/// Resolves the Indigo HID digitizer target for a display plane.
///
/// Every answer is a registration, because a target is only valid if
/// some create-service message registered it — see `IndigoHIDTouchTarget`.
///
/// CarPlay addresses its service's fixed target; the screen it shows
/// on has nothing to do with it. `derive` is kept for the caller's
/// shape and deliberately unused there: `IndigoHIDTargetForScreen`
/// over the CarPlay screen id gives `0x40000002`, which nothing
/// registered, and sending there restarted the guest.
///
/// The phone plane addresses the bound panel's own digitizer when a
/// panel is bound (`connectedScreenId`), and the built-in slot when
/// none is. The two coincide on every single-panel device; they part
/// on a foldable, where the slot belongs to the last panel created
/// and the phone plane wants the lit one.
enum DisplayTouchTarget {
    static func resolve(
        kind: DisplayKind,
        connectedScreenId: UInt32?,
        derive: (UInt32) -> UInt32?,
        override: UInt32? = nil
    ) -> UInt32? {
        switch kind {
        case .phone:
            guard let screenId = connectedScreenId, screenId != 0 else {
                return IndigoHIDTouchTarget.phone
            }
            return IndigoHIDTouchTarget.panel(screenId: screenId)
        case .carPlay:
            return override ?? IndigoHIDTouchTarget.carPlay
        }
    }

    /// Parses a probe override — `BAGUETTE_CARPLAY_TARGET`, decimal or
    /// `0x`-prefixed. Exists because finding the right target is a
    /// search: the guest publishes the registered set only when it
    /// rejects one, and rebuilding between candidates is far slower
    /// than restarting with a different number.
    ///
    /// The search runs over `knownProbeTargets` and nowhere else, so
    /// that is what this accepts. Anything outside it — a typo, a
    /// number `IndigoHIDTargetForScreen` handed back, a guess — is by
    /// definition a target no service registered, and dispatching there
    /// is what takes `backboardd` and SpringBoard down. An env var is
    /// not a good place to be able to do that from.
    ///
    /// Rejected input yields `nil` rather than something arbitrary, so
    /// the caller falls back to the known-good constant.
    static func parseOverride(_ raw: String?) -> UInt32? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        var radix = 10
        if text.lowercased().hasPrefix("0x") {
            radix = 16
            text = String(text.dropFirst(2))
        }
        guard let target = UInt32(text, radix: radix),
              IndigoHIDTouchTarget.knownProbeTargets.contains(target)
        else {
            return nil
        }
        return target
    }
}
