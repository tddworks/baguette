import Foundation
import CryptoKit

/// Pure factory: turns a (dylib-bytes, support-dir) pair into the
/// install layout. Per-hash subdirs dodge the iOS Simulator's dyld
/// page-hash cache rejecting replaced dylibs at the same path with
/// `code:codesigning(3) invalid-page(2)` — every release ships a
/// different sha12, gets a different install path.
struct VirtualCameraInstallPlan: Equatable {
    let sha12: String
    let buildDir: String
    let destPath: String

    static func compute(bytes: Data, supportDir: String) -> VirtualCameraInstallPlan {
        let sha = String(sha256Hex(bytes).prefix(12))
        let buildDir = (supportDir as NSString).appendingPathComponent("builds/\(sha)")
        let destPath = (buildDir as NSString).appendingPathComponent("VirtualCamera.dylib")
        return VirtualCameraInstallPlan(sha12: sha, buildDir: buildDir, destPath: destPath)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
