import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// The pure decision behind "should we install from this bakery?".
/// The consent *interaction* (a terminal y/N or a browser modal) lives
/// in the App layer; this decides whether that interaction is even
/// needed and builds the warning text.
///
/// Trust is **per bakery, once**: a source you've already accepted, or
/// one you accept explicitly (`--yes` / the browser Install click),
/// needs no prompt. Only a brand-new, unaccepted source must be asked.
enum TrustDecision {

    enum Outcome: Equatable {
        case granted
        case mustAsk
    }

    static func decide(alreadyTrusted: Bool, accepted: Bool) -> Outcome {
        (alreadyTrusted || accepted) ? .granted : .mustAsk
    }

    /// The consent warning. Names the source and the exact commit being
    /// pinned, and states plainly what accepting means — that a
    /// plugin's code runs as a real program with the user's own
    /// permissions, the boundary `brew install` already crosses.
    static func prompt(source: String, commit: String) -> String {
        """
        ⚠  Add bakery "\(source)" (commit \(commit))?

           Plugins from this bakery run as programs on your Mac with your
           own permissions — the same trust you extend to anything you
           install. Only add sources you trust. Installing copies files;
           nothing runs until you activate a plugin.
        """
    }
}
