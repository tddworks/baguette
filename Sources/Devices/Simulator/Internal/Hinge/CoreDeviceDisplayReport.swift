import BaguetteDevice
import Foundation

/// What `devicectl device info displays --json-output -` says about a
/// foldable: which of its built-in displays is active. The cover is the
/// one Core Device calls `primary`, as baguette calls it `.primary`.
enum CoreDeviceDisplayReport {
    private struct Report: Decodable {
        struct Result: Decodable { let displays: [Display] }
        struct Display: Decodable {
            struct Kind: Decodable { let integrated: Empty? }
            struct Empty: Decodable {}
            let type: Kind
            let primary: Bool
            let active: Bool
        }
        let result: Result
    }

    /// The built-in panel Core Device marks active, or nil when it marks
    /// none or the answer can't be read.
    static func presentingPanel(in data: Data) -> IntegratedPanel? {
        guard let report = try? JSONDecoder().decode(Report.self, from: data),
              let active = report.result.displays.first(where: { $0.type.integrated != nil && $0.active })
        else { return nil }
        return active.primary ? .primary : .secondary
    }
}
