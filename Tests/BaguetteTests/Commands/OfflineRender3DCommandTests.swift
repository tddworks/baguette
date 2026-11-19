import ArgumentParser
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("OfflineRender3DCommand")
struct OfflineRender3DCommandTests {
    @Test func `should explain an unsupported fold request`() {
        #expect(Render3DCommand.message(for: DeviceModelError.modelCannotFold("iphone-17"))
            == "Model 'iphone-17' cannot fold; omit --hinge-degrees or choose a foldable model.")
        #expect(Render3DCommand.message(for: DeviceModelError.invalidHingeAngle)
            == "The hinge angle must be finite and between 0 and 180 degrees.")
    }

    @Test func `should say an unreadable screen image is not a readable PNG or JPEG`() {
        #expect(Render3DCommand.message(for: DeviceModelError.screenImageInvalid)
            == "The screen image is not a readable PNG or JPEG.")
    }

    @Test(arguments: [["--hinge-degrees", "130"], ["--screen-orientation", "landscape-left"], ["--screen-orientation", "portrait"]])
    func `should reject offline pose options for a live capture`(option: [String]) {
        #expect(throws: (any Error).self) {
            _ = try Render3DCommand.parse(["--udid", "device"] + option)
        }
    }

    @Test(arguments: ["portrait", "landscape-left", "landscape-right", "portrait-upside-down"])
    func `should take the orientation an offline screenshot was captured in`(name: String) throws {
        let command = try Render3DCommand.parse([
            "--screen", "screen.png", "--device", "iphone-duo",
            "--screen-orientation", name, "--hinge-degrees", "130"
        ])
        #expect(command.screenOrientation == DeviceOrientation(wireName: name))
        #expect(command.hingeDegrees == 130)
    }

    @Test func `should leave the pose unrotated and unspecified when no pose options are given`() throws {
        let command = try Render3DCommand.parse(["--screen", "screen.png", "--device", "iphone-duo"])
        #expect(command.screenOrientation == nil)
        #expect(command.hingeDegrees == nil)
    }

    /// The render plan rejects an angle off 0...180 with
    /// `DeviceModelError.invalidHingeAngle`; the command does not check it twice.
    @Test(arguments: ["181", "nan", "inf"])
    func `should leave the hinge range check to the render plan`(value: String) throws {
        let command = try Render3DCommand.parse([
            "--screen", "screen.png", "--device", "iphone-duo", "--hinge-degrees", value
        ])
        #expect(command.hingeDegrees.map { !$0.isFinite || $0 > 180 } == true)
    }

    @Test(arguments: ["landscapeLeft", "90", "sideways"])
    func `should reject unknown screen orientations`(value: String) {
        #expect(throws: (any Error).self) {
            try Render3DCommand.parse([
                "--screen", "screen.png", "--device", "iphone-duo", "--screen-orientation", value
            ])
        }
    }
}
