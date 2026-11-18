import Foundation
import Mockable

/// The Apple Watch simulator paired with a phone simulator. Its own
/// device in the set — its own udid, its own boot state, its own
/// framebuffer — so the browser streams it exactly like any other
/// device once it knows which one it is.
struct PairedWatch: Sendable, Equatable {
    let udid: String
    let name: String
    let state: SimulatorState
}

/// One phone's side of the host's pairing table. Named for what it is
/// in the domain — a pairing — not for the `simctl` call behind it.
@Mockable
protocol WatchPairing: Sendable {
    /// The watch paired with this phone, or nil when it has none.
    var watch: PairedWatch? { get }
}

/// Pure parser over `xcrun simctl list pairs -j`.
///
/// The table is the whole host's, keyed by pair id, and each row names
/// both sides. A phone's watch is the watch of the row whose phone side
/// carries that phone's udid; every other row belongs to a different
/// phone. Anything malformed reads as "no pair" — a device with no
/// watch and a device we couldn't ask about both mean the same thing to
/// the caller, which is that there is no watch to offer.
enum SimctlPairs {
    static func watch(pairedWith phoneUdid: String, in json: String) -> PairedWatch? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let root = object as? [String: Any],
              let pairs = root["pairs"] as? [String: Any]
        else { return nil }

        for (_, value) in pairs {
            guard let pair = value as? [String: Any],
                  let phone = pair["phone"] as? [String: Any],
                  phone["udid"] as? String == phoneUdid,
                  let watch = pair["watch"] as? [String: Any],
                  let udid = watch["udid"] as? String,
                  let name = watch["name"] as? String
            else { continue }
            return PairedWatch(
                udid: udid,
                name: name,
                state: SimulatorState.named(watch["state"] as? String ?? "")
            )
        }
        return nil
    }
}
