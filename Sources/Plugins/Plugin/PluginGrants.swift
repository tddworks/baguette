import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// Capability grants, issued per command invocation.
///
/// This is what makes a manifest's `capabilities` list mean something.
/// A single shared session token can't: every plugin would present the
/// same credential, so the server could never tell which plugin was
/// calling and any plugin could do anything any other was allowed.
/// Instead each invocation gets its own unguessable token bound to the
/// issuing plugin's declared set, and the token is revoked when the
/// command exits — so a leaked one is useless afterwards.
///
/// Thread-safe because it's written by the dispatcher and read by
/// route handlers on other threads.
final class PluginGrants: @unchecked Sendable {
    private struct Grant {
        let plugin: String
        let capabilities: [PluginCapability]
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]

    init() {}

    /// Mint a token granting `capabilities` for the life of one
    /// invocation. 32 hex chars from the system CSPRNG.
    func issue(plugin: String, capabilities: [PluginCapability]) -> String {
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        lock.lock(); defer { lock.unlock() }
        grants[token] = Grant(plugin: plugin, capabilities: capabilities)
        return token
    }

    func revoke(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        grants.removeValue(forKey: token)
    }

    /// The capabilities a token carries, or nil when it isn't a live
    /// grant (unknown, or already revoked).
    func capabilities(for token: String) -> [PluginCapability]? {
        lock.lock(); defer { lock.unlock() }
        return grants[token]?.capabilities
    }

    /// The authorization question the routes ask. Absent, empty and
    /// unknown tokens all grant nothing — least privilege by default.
    func allows(token: String?, capability: PluginCapability) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return capabilities(for: token)?.contains(capability) ?? false
    }

    /// Which plugin a token belongs to — for error messages that name
    /// the offender rather than saying a bare "forbidden".
    func plugin(for token: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return grants[token]?.plugin
    }
}
