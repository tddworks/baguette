import Testing
import Foundation
import ArgumentParser
import Mockable
@testable import Baguette
@testable import BaguetteDevice

@Suite("ChromeCommand")
struct ChromeCommandTests {

    // MARK: - command tree

    @Test func `should offer baguette chrome with two subcommands`() {
        let cfg = ChromeCommand.configuration
        #expect(cfg.commandName == "chrome")
        #expect(cfg.subcommands.count == 2)
    }

    @Test func `should offer a chrome layout subcommand`() {
        #expect(ChromeCommand.Layout.configuration.commandName == "layout")
    }

    @Test func `should offer a chrome composite subcommand`() {
        #expect(ChromeCommand.Composite.configuration.commandName == "composite")
    }

    // MARK: - error descriptions

    @Test func `should ask for --udid or --device-name when no target is given`() {
        let err: ChromeCommandError = .missingTarget
        #expect(String(describing: err) == "expected --udid or --device-name")
    }

    @Test func `should name the udid when no simulator has it`() {
        let err: ChromeCommandError = .simulatorNotFound(udid: "ABC")
        #expect(String(describing: err) == "no simulator with udid ABC")
    }

    @Test func `should name the target when no chrome bundle covers it`() {
        let err: ChromeCommandError = .notFound(target: "\"iPhone 17 Pro\"")
        #expect(String(describing: err) == #"no chrome bundle covers "iPhone 17 Pro""#)
    }

    // MARK: - ChromeTarget label fan-in

    @Test func `should label the target by udid when --udid is set`() throws {
        let target = try ChromeTarget.parse(["--udid", "ABCD-1234"])
        #expect(target.label == "udid ABCD-1234")
    }

    @Test func `should label the target by device name when --udid is absent`() throws {
        let target = try ChromeTarget.parse(["--device-name", "iPhone 17 Pro"])
        #expect(target.label == "\"iPhone 17 Pro\"")
    }

    @Test func `should label the target as none when neither flag was supplied`() throws {
        let target = try ChromeTarget.parse([])
        #expect(target.label == "(none)")
    }

    // MARK: - ChromeTarget.resolveAssets

    @Test func `should look up the chrome by device name when --device-name is set`() throws {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        let assets = DeviceChromeAssets(
            chrome: Self.fixtureChrome,
            composite: ChromeImage(data: Data("PNG".utf8), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).willReturn(assets)

        let target = try ChromeTarget.parse(["--device-name", "iPhone 17 Pro"])
        let resolved = try target.resolveAssets(in: chromes)

        #expect(resolved == assets)
        verify(chromes).assets(forDeviceName: .value("iPhone 17 Pro")).called(1)
    }

    /// A foldable's unfolded panel has its own chrome; `--panel
    /// unfolded` asks for it by name instead of through the hinge, so a
    /// script can read the open pose's layout on a folded (or unbooted)
    /// device.
    @Test func `should read the unfolded panel's chrome when --panel unfolded is given`() throws {
        let chromes = MockChromes()
        let assets = DeviceChromeAssets(
            chrome: Self.fixtureChrome,
            composite: ChromeImage(data: Data("PNG".utf8), size: Size(width: 1, height: 1))
        )
        given(chromes).assets(forDeviceName: .value("iPhone Duo"), panel: .value(.secondary))
            .willReturn(assets)

        let target = try ChromeTarget.parse(["--device-name", "iPhone Duo", "--panel", "unfolded"])
        #expect(try target.resolveAssets(in: chromes) == assets)
    }

    @Test func `should accept only cover and unfolded for --panel`() throws {
        #expect(try ChromeTarget.parse(["--device-name", "x", "--panel", "cover"]).panel == .primary)
        #expect(try ChromeTarget.parse(["--device-name", "x", "--panel", "unfolded"]).panel == .secondary)
        #expect(try ChromeTarget.parse(["--device-name", "x"]).panel == nil)
        #expect(throws: (any Error).self) {
            try ChromeTarget.parse(["--device-name", "x", "--panel", "inner"])
        }
    }

    @Test func `should find no chrome when no bundle covers the device`() throws {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        given(chromes).assets(forDeviceName: .any).willReturn(nil)

        let target = try ChromeTarget.parse(["--device-name", "Apple TV"])
        #expect(try target.resolveAssets(in: chromes) == nil)
    }

    @Test func `should reject a chrome lookup when neither --udid nor --device-name is supplied`() throws {
        let chromes = MockChromes()
        given(chromes).panels(forDeviceName: .any).willReturn([.primary])
        let target = try ChromeTarget.parse([])

        #expect(throws: ChromeCommandError.self) {
            try target.resolveAssets(in: chromes)
        }
    }
}

private extension ChromeCommandTests {
    static let fixtureChrome = DeviceChrome(
        identifier: "phone11",
        screenInsets: Insets(top: 18, left: 18, bottom: 18, right: 18),
        outerCornerRadius: 80,
        buttons: [],
        compositeImageName: "PhoneComposite"
    )
}
