import Foundation

/// Resolves the current window-server frontmost in a fresh guest AX context.
enum GuestFrontmost {
    enum Failure: Error, Equatable, LocalizedError {
        case toolMissing
        case invalidResponse(udid: String, cause: String)

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                "The bundled HingeControl guest helper is missing; rebuild Baguette with its resource bundle."
            case .invalidResponse(let udid, let cause):
                "Frontmost application query for \(udid) returned invalid data: \(cause)"
            }
        }
    }

    static func pid(
        udid: String,
        deviceSetPath: String? = nil,
        tool: () -> String? = { InjectedDylibInstaller.installIfNeeded(.hingeControl) },
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) throws -> Int32 {
        guard let tool = tool() else { throw Failure.toolMissing }
        let output = try SimctlCapture.run(
            udid: udid,
            arguments: ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? [])
                + ["spawn", udid, tool, "frontmost"],
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
