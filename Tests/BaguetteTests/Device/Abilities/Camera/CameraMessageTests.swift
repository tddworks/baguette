import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("CameraMessage parsing")
struct CameraMessageTests {

    @Test func `should read a camera_list message`() throws {
        let msg = try CameraMessage.parse(["type": "camera_list"])
        #expect(msg == .list)
    }

    @Test func `should read camera_start for a webcam with its fit and mirror flags`() throws {
        let msg = try CameraMessage.parse([
            "type": "camera_start",
            "deviceUID": "U-1",
            "fit": "fill",
            "mirror": true,
        ])
        #expect(msg == .start(
            source: .webcam(deviceUID: "U-1"),
            flags: CameraFlags(fillGravity: true, mirror: true)
        ))
    }

    @Test func `should read camera_start with an explicit webcam source like the default`() throws {
        let msg = try CameraMessage.parse([
            "type": "camera_start", "source": "webcam", "deviceUID": "U-1",
        ])
        #expect(msg == .start(source: .webcam(deviceUID: "U-1"), flags: CameraFlags()))
    }

    @Test func `should read camera_start for an image source without a deviceUID`() throws {
        let msg = try CameraMessage.parse([
            "type": "camera_start", "source": "image", "fit": "fill",
        ])
        #expect(msg == .start(
            source: .image,
            flags: CameraFlags(fillGravity: true, mirror: false)
        ))
    }

    @Test func `should read camera_start for a video source without a deviceUID`() throws {
        let msg = try CameraMessage.parse([
            "type": "camera_start", "source": "video",
        ])
        #expect(msg == .start(source: .video, flags: CameraFlags()))
    }

    @Test func `should reject camera_start when the source kind is unknown`() {
        #expect(throws: (any Error).self) {
            try CameraMessage.parse(["type": "camera_start", "source": "hologram"])
        }
    }

    @Test func `should fit without mirroring when camera_start carries no flags`() throws {
        let msg = try CameraMessage.parse([
            "type": "camera_start", "deviceUID": "U",
        ])
        #expect(msg == .start(source: .webcam(deviceUID: "U"), flags: CameraFlags()))
    }

    @Test func `should read a camera_stop message`() throws {
        let msg = try CameraMessage.parse(["type": "camera_stop"])
        #expect(msg == .stop)
    }

    @Test func `should read a camera_set_flags message`() throws {
        let msg = try CameraMessage.parse([
            "type": "camera_set_flags",
            "fit": "fit",
            "mirror": true,
        ])
        #expect(msg == .setFlags(CameraFlags(fillGravity: false, mirror: true)))
    }

    @Test func `should reject a camera message when its type is unknown`() {
        #expect(throws: (any Error).self) {
            try CameraMessage.parse(["type": "camera_wibble"])
        }
    }

    @Test func `should reject a webcam camera_start when deviceUID is missing`() {
        #expect(throws: (any Error).self) {
            try CameraMessage.parse(["type": "camera_start"])
        }
    }
}
