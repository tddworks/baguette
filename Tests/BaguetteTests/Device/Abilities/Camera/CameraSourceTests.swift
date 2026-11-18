import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("CameraSource")
struct CameraSourceTests {

    @Test func `should describe a webcam source as the webcam kind on the wire`() {
        #expect(CameraSource.device(uid: "U-1").wireKind == "webcam")
    }

    @Test func `should describe an image-file source as the image kind on the wire`() {
        #expect(CameraSource.image(path: "/tmp/pic.png").wireKind == "image")
    }

    @Test func `should describe a video-file source as the video kind on the wire`() {
        #expect(CameraSource.video(path: "/tmp/clip.mp4").wireKind == "video")
    }

    @Test func `should treat camera sources as equal only by kind and payload`() {
        #expect(CameraSource.device(uid: "U") == CameraSource.device(uid: "U"))
        #expect(CameraSource.device(uid: "U") != CameraSource.device(uid: "V"))
        #expect(CameraSource.image(path: "/a") != CameraSource.video(path: "/a"))
    }
}
