import BaguetteDevice
import BaguetteDeviceFamilies
import ArgumentParser
import Foundation

/// `baguette install --udid <UDID> <path>`
///
/// Installs an app bundle (`.ipa` / `.app`) onto a booted simulator —
/// the CLI mirror of dragging an app onto the device in `baguette
/// serve`. Backed by `xcrun simctl install`. Classification (is this an
/// app?) lives on the Domain value `AppBundle`; the spawn is in
/// `Devices/Simulator/Internal/Apps/SimctlApps.swift`.
struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an app (.ipa/.app) onto the booted simulator"
    )

    @OptionGroup var options: DeviceOption

    @Argument(help: "Path to the .ipa or .app to install")
    var path: String

    func run() async throws {
        let device = try options.device()
        let apps = try orExit { try device.require(.apps) }
        let url = URL(fileURLWithPath: path)
        guard let app = AppBundle.at(url) else {
            tell("Not an installable app (expected .ipa or .app): \(path)")
            throw ExitCode.failure
        }
        do {
            try await apps.install(app)
        } catch {
            tell("install failed: \(error)")
            throw ExitCode.failure
        }
        tell("Installed \(url.lastPathComponent) on \(device.name)")
    }
}

/// `baguette add-media --udid <UDID> <path>`
///
/// Adds a photo or video to a booted simulator's Photos library — the
/// CLI mirror of dragging media onto the device in `baguette serve`.
/// Backed by `xcrun simctl addmedia`. Classification lives on the
/// Domain value `MediaItem`; the spawn is in
/// `Devices/Simulator/Internal/Photos/SimctlPhotoLibrary.swift`.
struct AddMediaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-media",
        abstract: "Add a photo or video to the booted simulator's Photos"
    )

    @OptionGroup var options: DeviceOption

    @Argument(help: "Path to the image or video to add")
    var path: String

    func run() async throws {
        let device = try options.device()
        let photos = try orExit { try device.require(.photos) }
        let url = URL(fileURLWithPath: path)
        guard let media = MediaItem.at(url) else {
            tell("Not a supported image or video: \(path)")
            throw ExitCode.failure
        }
        do {
            try await photos.add(media)
        } catch {
            tell("add-media failed: \(error)")
            throw ExitCode.failure
        }
        tell("Added \(url.lastPathComponent) to \(device.name) Photos")
    }
}
