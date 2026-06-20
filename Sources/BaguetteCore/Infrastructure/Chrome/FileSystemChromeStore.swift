import Foundation

/// Production `ChromeStore` — reads from the standard Apple paths.
/// Roots are injectable so tests can point at a tmp directory; the
/// defaults are what every Mac with Xcode installed already has.
struct FileSystemChromeStore: ChromeStore {
    let deviceTypesRoot: String
    let chromeRoot: String

    init(
        deviceTypesRoot: String = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes",
        chromeRoot: String = "/Library/Developer/DeviceKit/Chrome"
    ) {
        self.deviceTypesRoot = deviceTypesRoot
        self.chromeRoot = chromeRoot
    }

    func profilePlistData(deviceName: String) throws -> Data {
        let path = "\(deviceTypesRoot)/\(deviceName).simdevicetype/Contents/Resources/profile.plist"
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func chromeJSONData(chromeIdentifier: String) throws -> Data {
        let path = "\(chromeRoot)/\(chromeIdentifier).devicechrome/Contents/Resources/chrome.json"
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func chromeAssetPDF(chromeIdentifier: String, imageName: String) throws -> Data {
        let path = "\(chromeRoot)/\(chromeIdentifier).devicechrome/Contents/Resources/\(imageName).pdf"
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
