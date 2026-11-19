import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

// Device Hub's pose picker, on the page: shut, open or flat, driven on the
// device's own hinge. The envelope rides the 3D socket beside
// `set_3d_camera`.
@Suite("Device3DPose")
struct Device3DPoseTests {
    @Test func `should read a set_pose envelope as a pose to fold to`() throws {
        let pose = try #require(try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":130}"#.utf8)))
        #expect(pose == .fold(hingeDegrees: 130, duration: nil))
    }

    @Test func `should take an optional sweep duration on a pose and reject a negative one`() throws {
        let picked = try #require(try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":130}"#.utf8)))
        #expect(picked == .fold(hingeDegrees: 130, duration: nil))
        let dragged = try #require(try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":72.5,"duration":0}"#.utf8)))
        #expect(dragged == .fold(hingeDegrees: 72.5, duration: 0))
        #expect(throws: HingeCommandError.invalidDuration) {
            _ = try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":90,"duration":-1}"#.utf8))
        }
    }

    @Test func `should reject a pose swept for longer than a minute`() throws {
        let slow = try #require(try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":90,"duration":60}"#.utf8)))
        #expect(slow == .fold(hingeDegrees: 90, duration: 60))
        for duration in ["60.1", "1e300"] {
            #expect(throws: HingeCommandError.invalidDuration) {
                _ = try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":90,"duration":\#(duration)}"#.utf8))
            }
        }
    }

    /// A pose the socket cannot play is refused as the hinge route
    /// refuses it, so the page can be told what was wrong.
    @Test func `should ignore other envelopes and reject angles off the hinge`() throws {
        #expect(try Device3DPose.parsing(json: Data(#"{"type":"set_fps","fps":30}"#.utf8)) == nil)
        #expect(throws: HingeCommandError.angleOutOfRange) {
            _ = try Device3DPose.parsing(json: Data(#"{"type":"set_pose","hingeDegrees":200}"#.utf8))
        }
        #expect(throws: HingeCommandError.angleOutOfRange) {
            _ = try Device3DPose.parsing(json: Data(#"{"type":"set_pose"}"#.utf8))
        }
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DPose.parsing(json: Data("not json".utf8))
        }
    }
}
