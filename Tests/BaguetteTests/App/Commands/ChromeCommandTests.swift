import Testing
import Foundation
import ArgumentParser
import Mockable
@testable import Baguette

@Suite("ChromeCommand")
struct ChromeCommandTests {

    // MARK: - command tree

    @Test func `chrome command is named chrome with two leaves`() {
        let cfg = ChromeCommand.configuration
        #expect(cfg.commandName == "chrome")
        #expect(cfg.subcommands.count == 2)
    }

    @Test func `layout subcommand is named layout`() {
        #expect(ChromeCommand.Layout.configuration.commandName == "layout")
    }

    @Test func `composite subcommand is named composite`() {
        #expect(ChromeCommand.Composite.configuration.commandName == "composite")
    }

    // MARK: - error descriptions

    @Test func `missingTarget describes the expected flag pair`() {
        let err: ChromeCommandError = .missingTarget
        #expect(String(describing: err) == "expected --udid or --device-name")
    }

    @Test func `simulatorNotFound includes the udid`() {
        let err: ChromeCommandError = .simulatorNotFound(udid: "ABC")
        #expect(String(describing: err) == "no simulator with udid ABC")
    }

    @Test func `notFound includes the target label`() {
        let err: ChromeCommandError = .notFound(target: "\"iPhone 17 Pro\"")
        #expect(String(describing: err) == #"no chrome bundle covers "iPhone 17 Pro""#)
    }

    // MARK: - ChromeTarget label fan-in

    @Test func `label prefers udid when set`() throws {
        let target = try ChromeTarget.parse(["--udid", "ABCD-1234"])
        #expect(target.label == "udid ABCD-1234")
    }

    @Test func `label uses device-name when udid is absent`() throws {
        let target = try ChromeTarget.parse(["--device-name", "iPhone 17 Pro"])
        #expect(target.label == "\"iPhone 17 Pro\"")
    }

    @Test func `label is (none) when neither flag was supplied`() throws {
        let target = try ChromeTarget.parse([])
        #expect(target.label == "(none)")
    }

    // MARK: - ChromeTarget.resolveAssets

    @Test func `resolveAssets routes through chromes when device-name is set`() throws {
        let chromes = MockChromes()
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

    @Test func `resolveAssets returns nil when chromes has no bundle for the device`() throws {
        let chromes = MockChromes()
        given(chromes).assets(forDeviceName: .any).willReturn(nil)

        let target = try ChromeTarget.parse(["--device-name", "Apple TV"])
        #expect(try target.resolveAssets(in: chromes) == nil)
    }

    @Test func `resolveAssets throws missingTarget when neither flag is supplied`() throws {
        let chromes = MockChromes()
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
