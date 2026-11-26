import BaguetteDevice
import Foundation

/// The irreducible call: one `devicectl device info displays` run for a
/// simulator, about a third of a second, its JSON read by
/// `CoreDeviceDisplayReport`.
enum CoreDeviceDisplays {
    static func presentingPanel(udid: String) -> IntegratedPanel? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "devicectl", "device", "info", "displays", "--device", udid,
            "--quiet", "--json-output", "-", "--timeout", "10",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return CoreDeviceDisplayReport.presentingPanel(in: data)
    }
}
