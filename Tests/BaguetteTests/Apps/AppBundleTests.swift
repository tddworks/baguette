import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `AppBundle` — the thing the user means when
/// they say "install an app." `AppBundle.at(_:)` is the classification:
/// it answers "is this file an app I can install?" by extension, with
/// no disk access (so the serve route can reject before reading a
/// 60 MB body). `installArguments` is the argv tail handed to
/// `xcrun simctl install <udid> <path>`.
@Suite("AppBundle")
struct AppBundleTests {

    @Test func `should treat an .ipa file as an installable app`() {
        let url = URL(fileURLWithPath: "/tmp/MyApp.ipa")
        #expect(AppBundle.at(url) == AppBundle(path: url))
    }

    @Test func `should treat a .app bundle as an installable app`() {
        let url = URL(fileURLWithPath: "/tmp/MyApp.app")
        #expect(AppBundle.at(url) == AppBundle(path: url))
    }

    @Test func `should recognise an .ipa whatever the case of its extension`() {
        let url = URL(fileURLWithPath: "/tmp/MyApp.IPA")
        #expect(AppBundle.at(url) == AppBundle(path: url))
    }

    @Test func `should not treat a photo as an app`() {
        #expect(AppBundle.at(URL(fileURLWithPath: "/tmp/photo.png")) == nil)
    }

    @Test func `should not treat a generic document as an app`() {
        #expect(AppBundle.at(URL(fileURLWithPath: "/tmp/notes.pdf")) == nil)
    }

    @Test func `should not treat an extension-less file as an app`() {
        #expect(AppBundle.at(URL(fileURLWithPath: "/tmp/Makefile")) == nil)
    }

    @Test func `should install an app with simctl install on the device`() {
        let app = AppBundle(path: URL(fileURLWithPath: "/tmp/My App.ipa"))
        #expect(app.installArguments(udid: "U") == ["simctl", "install", "U", "/tmp/My App.ipa"])
    }

    @Test func `should install an app inside the device's custom device set when it lives in one`() {
        let app = AppBundle(path: URL(fileURLWithPath: "/tmp/My App.ipa"))
        #expect(app.installArguments(udid: "U", deviceSetPath: "/custom set")
            == ["simctl", "--set", "/custom set", "install", "U", "/tmp/My App.ipa"])
    }
}
