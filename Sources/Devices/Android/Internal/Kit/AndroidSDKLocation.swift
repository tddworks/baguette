import Foundation

/// Where the Android SDK's tools are: the SDK `ANDROID_HOME` (or the older
/// `ANDROID_SDK_ROOT`) names, then Android Studio's own SDK — and for adb,
/// also where Homebrew installs platform-tools. The first that is there;
/// none means none.
enum AndroidSDKLocation {
    static func adb(environment: [String: String] = ProcessInfo.processInfo.environment,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        first(in: sdks(environment, home).map { "\($0)/platform-tools/adb" } + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"],
              isExecutable)
    }

    static func emulator(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        first(in: sdks(environment, home).map { "\($0)/emulator/emulator" }, isExecutable)
    }

    private static func sdks(_ environment: [String: String], _ home: URL) -> [String] {
        [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"],
         home.appendingPathComponent("Library/Android/sdk").path].compactMap { $0 }
    }

    private static func first(in candidates: [String], _ isExecutable: (String) -> Bool) -> URL? {
        candidates.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }
}
