import Foundation

/// Where `adb` is: in the SDK `ANDROID_HOME` (or the older `ANDROID_SDK_ROOT`)
/// names, in Android Studio's own SDK, or where Homebrew installs
/// platform-tools — the first that is there. None means no Android devices.
enum AdbLocation {
    static func find(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        let sdks = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
                    home.appendingPathComponent("Library/Android/sdk").path].compactMap { $0 }
        let candidates = sdks.map { "\($0)/platform-tools/adb" } + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }
}
