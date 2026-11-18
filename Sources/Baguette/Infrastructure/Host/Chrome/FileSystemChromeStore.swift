import Foundation

/// Production `ChromeStore` — reads from the standard Apple paths.
/// Roots are injectable so tests can point at a tmp directory; the
/// defaults are what every Mac with Xcode installed already has.
struct FileSystemChromeStore: ChromeStore {
    let deviceTypesRoot: String
    let chromeRoot: String
    let masksRoot: String

    init(
        deviceTypesRoot: String = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes",
        chromeRoot: String = "/Library/Developer/DeviceKit/Chrome",
        masksRoot: String = "/Library/Developer/DeviceKit/FramebufferMasks"
    ) {
        self.deviceTypesRoot = deviceTypesRoot
        self.chromeRoot = chromeRoot
        self.masksRoot = masksRoot
    }

    func framebufferMaskPDF(identifier: String) throws -> Data {
        // The identifier is a UUID from a plist Apple wrote; refuse
        // anything that could walk out of the masks directory.
        guard !identifier.contains("/"), !identifier.contains("..") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: URL(fileURLWithPath: "\(masksRoot)/\(identifier).pdf"))
    }

    func profilePlistData(deviceName: String) throws -> Data {
        let path = "\(deviceTypesRoot)/\(deviceName).simdevicetype/Contents/Resources/profile.plist"
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func capabilitiesPlistData(deviceName: String) throws -> Data {
        let path = "\(deviceTypesRoot)/\(deviceName).simdevicetype/Contents/Resources/capabilities.plist"
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
