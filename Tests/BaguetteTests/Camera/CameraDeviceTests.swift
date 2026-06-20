import Testing
import Foundation
@testable import BaguetteCore

@Suite("CameraDevice")
struct CameraDeviceTests {
    @Test func `equality is structural`() {
        let a = CameraDevice(uid: "u-1", name: "FaceTime HD", isDefault: true)
        let b = CameraDevice(uid: "u-1", name: "FaceTime HD", isDefault: true)
        let c = CameraDevice(uid: "u-2", name: "FaceTime HD", isDefault: true)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func `serializes to wire JSON shape`() {
        let d = CameraDevice(uid: "u-1", name: "FaceTime HD", isDefault: true)
        #expect(d.wireDictionary as NSDictionary == [
            "uid": "u-1",
            "name": "FaceTime HD",
            "isDefault": true,
        ] as NSDictionary)
    }
}
