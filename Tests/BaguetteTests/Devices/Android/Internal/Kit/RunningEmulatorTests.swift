import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies

/// A running emulator's discovery file, read as where its control API is.
@Suite("RunningEmulator")
struct RunningEmulatorTests {
    private static let ini = """
        emulator.build=16740729
        avd.id=baguette_pixel
        port.serial=5554
        port.adb=5555
        avd.name=baguette_pixel
        grpc.port=8554
        grpc.token=s3cr3t-token
        """

    @Test func `should read where a running emulator's control API answers`() {
        let found = RunningEmulator(ini: Self.ini)

        #expect(found == RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", port: 8554, token: "s3cr3t-token"))
    }

    @Test func `should know an emulator started without gRPC by its AVD, with no control API`() {
        #expect(RunningEmulator(ini: "port.serial=5554\navd.name=baguette_pixel\n")
            == RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", control: nil))
    }

    @Test func `should find the emulators running from their discovery files`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("running-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.ini.write(to: folder.appendingPathComponent("pid_95363.ini"), atomically: true, encoding: .utf8)
        try "port.serial=5556\n".write(to: folder.appendingPathComponent("pid_1.ini"), atomically: true, encoding: .utf8)
        try "not an emulator".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        #expect(RunningEmulator.all(in: folder).map(\.serial) == ["emulator-5556", "emulator-5554"])
    }

    @Test func `should find no emulators running when the folder isn't there`() {
        #expect(RunningEmulator.all(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }
}
