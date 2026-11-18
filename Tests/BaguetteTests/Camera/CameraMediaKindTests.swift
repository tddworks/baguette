import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("CameraMediaKind")
struct CameraMediaKindTests {

    @Test func `should treat still-image files as an image source`() {
        for ext in ["png", "jpg", "jpeg", "gif", "heic", "heif"] {
            #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/pic.\(ext)")) == .image)
        }
    }

    @Test func `should treat movie files as a video source`() {
        for ext in ["mov", "mp4", "m4v"] {
            #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/clip.\(ext)")) == .video)
        }
    }

    @Test func `should recognise a media file whatever the case of its extension`() {
        #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/PIC.PNG")) == .image)
        #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/CLIP.MP4")) == .video)
    }

    @Test func `should refuse a file when the camera cannot source from its extension`() {
        #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/doc.pdf")) == nil)
        #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/app.ipa")) == nil)
        #expect(CameraMediaKind.at(URL(fileURLWithPath: "/tmp/noext")) == nil)
    }
}
