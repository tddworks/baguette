import BaguetteDevice
import Foundation

/// The frontmost app, asked of the guest's own accessibility server through
/// AXPTranslator: `xcrun simctl spawn <udid> <AXPFrontmost> frontmost`, a fresh
/// accessibility context per query, which also wakes a freshly launched app's
/// tree for the host's next read.
enum AXPTranslatorFrontmost {
    enum Failure: Error, Equatable, LocalizedError {
        case programMissing
        /// `AXPFrontmost` is built for the iOS simulator; this guest runs another OS.
        case unsupportedRuntime(String)
        case invalidResponse(udid: String, cause: String)

        var errorDescription: String? {
            switch self {
            case .programMissing:
                "The bundled AXPFrontmost program is missing; rebuild Baguette with its resource bundle."
            case .unsupportedRuntime(let runtime):
                "AXPFrontmost runs only in an iOS simulator, not \(runtime)."
            case .invalidResponse(let udid, let cause):
                "Frontmost application query for \(udid) returned invalid data: \(cause)"
            }
        }
    }

    /// Whether `AXPFrontmost` can run in a guest of this runtime (`iOS 27.1`,
    /// `watchOS 11.2`): it is built for the iOS simulator only.
    static func runs(onRuntime runtime: String) -> Bool {
        DeviceKind.Platform(runtime: runtime) == .iOS
    }

    static func pid(
        udid: String,
        deviceSetPath: String? = nil,
        runtime: String? = nil,
        path: () -> String? = { InjectedDylibInstaller.installIfNeeded(.axpFrontmost) },
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) throws -> Int32 {
        if let runtime, !runs(onRuntime: runtime) { throw Failure.unsupportedRuntime(runtime) }
        guard let path = path() else { throw Failure.programMissing }
        let output = try SimctlCapture.run(
            udid: udid,
            arguments: ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? [])
                + ["spawn", udid, path, "frontmost"],
            // Guest AX is bounded to 4s after main starts. Allow separate time
            // for simctl/dyld startup and pipe drain.
            xcrun: xcrun, timeout: 10
        )
        do {
            return try AXFrontmost.pid(from: Data(output.stdout.utf8))
        } catch {
            throw Failure.invalidResponse(udid: udid, cause: "\(error.localizedDescription)\n\(output.combined)")
        }
    }
}
