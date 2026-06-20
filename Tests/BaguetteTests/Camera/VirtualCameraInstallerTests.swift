import Testing
import Foundation
import CryptoKit
@testable import BaguetteCore

@Suite("VirtualCameraInstallPlan")
struct VirtualCameraInstallPlanTests {

    @Test func `dest path is supportDir + builds + first 12 sha256 hex chars`() {
        let bytes = Data("hello".utf8)
        let plan = VirtualCameraInstallPlan.compute(
            bytes: bytes,
            supportDir: "/tmp/baguette-test"
        )
        // sha256("hello") prefix = "2cf24dba5fb0".
        #expect(plan.sha12 == "2cf24dba5fb0")
        #expect(plan.buildDir == "/tmp/baguette-test/builds/2cf24dba5fb0")
        #expect(plan.destPath == "/tmp/baguette-test/builds/2cf24dba5fb0/VirtualCamera.dylib")
    }

    @Test func `different bytes produce different per-hash dirs`() {
        let a = VirtualCameraInstallPlan.compute(bytes: Data([0x01]), supportDir: "/s")
        let b = VirtualCameraInstallPlan.compute(bytes: Data([0x02]), supportDir: "/s")
        #expect(a.buildDir != b.buildDir)
    }
}

@Suite("VirtualCameraInstaller — applies the plan to disk")
struct VirtualCameraInstallerApplyTests {

    @Test func `writes the dylib bytes to the computed destPath`() throws {
        let scratch = NSTemporaryDirectory() + "baguette-installer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let bytes = Data([0xAA, 0xBB, 0xCC])
        let plan = VirtualCameraInstallPlan.compute(bytes: bytes, supportDir: scratch)
        try VirtualCameraInstaller.apply(plan: plan, bytes: bytes)

        let written = try Data(contentsOf: URL(fileURLWithPath: plan.destPath))
        #expect(written == bytes)
    }

    @Test func `apply is idempotent — second call is a no-op when the file already exists`() throws {
        let scratch = NSTemporaryDirectory() + "baguette-installer-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let bytes = Data([0x01, 0x02, 0x03])
        let plan = VirtualCameraInstallPlan.compute(bytes: bytes, supportDir: scratch)
        try VirtualCameraInstaller.apply(plan: plan, bytes: bytes)
        // Touch the file with different mtime to detect a re-write.
        let url = URL(fileURLWithPath: plan.destPath)
        let before = try url.resourceValues(forKeys: [.contentModificationDateKey])
        Thread.sleep(forTimeInterval: 0.05)
        try VirtualCameraInstaller.apply(plan: plan, bytes: bytes)
        let after = try url.resourceValues(forKeys: [.contentModificationDateKey])
        #expect(before.contentModificationDate == after.contentModificationDate)
    }
}
