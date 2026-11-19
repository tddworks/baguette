import Foundation
import Testing
@testable import Baguette

/// Where `adb` is found: the SDK the environment names, Android Studio's own,
/// or Homebrew's.
@Suite("AdbLocation")
struct AdbLocationTests {
    private static let home = URL(fileURLWithPath: "/Users/someone")

    private static func find(_ environment: [String: String], installed: Set<String>) -> String? {
        AdbLocation.find(environment: environment, home: home, isExecutable: { installed.contains($0) })?.path
    }

    @Test func `should find adb in the SDK ANDROID_HOME names`() {
        #expect(Self.find(["ANDROID_HOME": "/sdk"], installed: ["/sdk/platform-tools/adb", "/opt/homebrew/bin/adb"])
            == "/sdk/platform-tools/adb")
    }

    @Test func `should find adb in the SDK ANDROID_SDK_ROOT names when ANDROID_HOME is unset`() {
        #expect(Self.find(["ANDROID_SDK_ROOT": "/old-sdk"], installed: ["/old-sdk/platform-tools/adb"])
            == "/old-sdk/platform-tools/adb")
    }

    @Test func `should find adb in Android Studio's SDK when no variable names one`() {
        #expect(Self.find([:], installed: ["/Users/someone/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb"])
            == "/Users/someone/Library/Android/sdk/platform-tools/adb")
    }

    @Test func `should find the adb Homebrew installed when there is no SDK`() {
        #expect(Self.find([:], installed: ["/opt/homebrew/bin/adb"]) == "/opt/homebrew/bin/adb")
        #expect(Self.find([:], installed: ["/usr/local/bin/adb"]) == "/usr/local/bin/adb")
    }

    @Test func `should find no adb when none is installed`() {
        #expect(Self.find(["ANDROID_HOME": "/sdk"], installed: []) == nil)
    }
}
