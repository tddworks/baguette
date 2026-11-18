import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("CameraDevice")
struct CameraDeviceTests {
    @Test func `should treat two cameras with the same details as the same camera`() {
        let a = CameraDevice(uid: "u-1", name: "FaceTime HD", isDefault: true)
        let b = CameraDevice(uid: "u-1", name: "FaceTime HD", isDefault: true)
        let c = CameraDevice(uid: "u-2", name: "FaceTime HD", isDefault: true)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func `should describe a camera on the wire as uid, name and isDefault`() {
        let d = CameraDevice(uid: "u-1", name: "FaceTime HD", isDefault: true)
        #expect(d.wireDictionary as NSDictionary == [
            "uid": "u-1",
            "name": "FaceTime HD",
            "isDefault": true,
        ] as NSDictionary)
    }
}
