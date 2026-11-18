import BaguetteDevice
import Foundation

/// What a request is allowed to do, once we've asked whether it's a
/// plugin.
///
/// Three answers, not two, and the third is the one that matters.
/// `anonymous` says *this caller never claimed to be a plugin* — no
/// grant was presented — so the capability table has nothing to say and
/// the existing browser-trust checks decide, exactly as they did before
/// plugins existed. That's what keeps `curl` and the browser working.
///
/// Presenting a token, on the other hand, is a claim, and a claim that
/// doesn't check out is refused rather than downgraded to `anonymous`.
/// Otherwise the way around the capability check would be to send a
/// stale token — or any garbage at all — instead of a real one.
enum PluginAccess: Equatable {
    /// No grant presented; not a plugin. Browser trust decides.
    case anonymous
    /// A live grant carrying the capability this route demands.
    case granted
    /// A grant that can't be here, with the reason to send back.
    case refused(String)
}

extension PluginAccess {

    /// Decide `path` for the bearer of `token`.
    static func decide(token: String?, path: String, grants: PluginGrants) -> PluginAccess {
        guard let token, !token.isEmpty else { return .anonymous }

        guard let carried = grants.capabilities(for: token) else {
            // Unknown or already revoked — the invocation it belonged to
            // has exited.
            return .refused("this grant is no longer valid")
        }

        guard let required = PluginRoute.capability(path: path) else {
            return .refused("no capability grants a plugin access to \(path)")
        }

        guard carried.contains(required) else {
            return .refused(#"this plugin did not declare the "\#(required.rawValue)" capability"#)
        }

        return .granted
    }
}
