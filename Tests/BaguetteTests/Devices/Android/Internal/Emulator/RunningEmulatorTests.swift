import Testing
@testable import Baguette

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

    @Test func `should read no control API from an emulator started without gRPC`() {
        #expect(RunningEmulator(ini: "port.serial=5554\navd.name=baguette_pixel\n") == nil)
    }
}
