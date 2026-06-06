import Foundation
import Security

/// Resolve a flow's originating app to its code-signing identifier (the
/// bundle id) on macOS. Unlike iOS, `NEFilterFlow` has no
/// `sourceAppIdentifier` string here — it exposes a `sourceAppAuditToken`,
/// which we turn into a signing identifier via the Security framework.
///
/// This is the integration-only edge that the design doc's spike is about:
/// what identifier a *simulator* app's flows actually carry on the host.
enum SourceApp {
    static func signingIdentifier(auditToken: Data?) -> String? {
        guard let auditToken else { return nil }
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        return dict[kSecCodeInfoIdentifier as String] as? String
    }
}
