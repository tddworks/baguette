import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `AppArchive` — a zip that carries an app.
/// The browser can't upload a folder-form `.app` bundle as one file, so
/// it packs the bundle into a zip and posts that instead; a user-zipped
/// `.app` arrives the same way. `AppArchive.at(_:)` classifies by
/// extension with no disk access (so the serve route can reject before
/// reading the body), `extractArguments(to:)` projects the
/// `ditto -x -k` argv tail, and `installableApp(amongExtracted:)`
/// answers "which entry is the app?" purely over the extracted
/// top-level names — exactly one `.app`, junk ignored, ambiguity
/// refused.
@Suite("AppArchive")
struct AppArchiveTests {

    // MARK: classification

    @Test func `should treat a .zip file as an app archive`() {
        let url = URL(fileURLWithPath: "/tmp/MyApp.app.zip")
        #expect(AppArchive.at(url) == AppArchive(path: url))
    }

    @Test func `should recognise an app archive whatever the case of its .zip extension`() {
        let url = URL(fileURLWithPath: "/tmp/MyApp.ZIP")
        #expect(AppArchive.at(url) == AppArchive(path: url))
    }

    @Test func `should not treat an .ipa as an app archive since it installs directly`() {
        #expect(AppArchive.at(URL(fileURLWithPath: "/tmp/MyApp.ipa")) == nil)
    }

    @Test func `should not treat a bare .app path as an app archive`() {
        #expect(AppArchive.at(URL(fileURLWithPath: "/tmp/MyApp.app")) == nil)
    }

    @Test func `should not treat media as an app archive`() {
        #expect(AppArchive.at(URL(fileURLWithPath: "/tmp/shot.png")) == nil)
    }

    // MARK: extraction argv

    @Test func `should extract an archive with ditto -x -k into the destination`() {
        let archive = AppArchive(path: URL(fileURLWithPath: "/tmp/up/My App.app.zip"))
        let dest = URL(fileURLWithPath: "/tmp/extract-1")
        #expect(archive.extractArguments(to: dest)
            == ["-x", "-k", "/tmp/up/My App.app.zip", "/tmp/extract-1"])
    }

    // MARK: locating the app among extracted entries

    @Test func `should install the single top-level .app found in an archive`() {
        #expect(AppArchive.installableApp(amongExtracted: ["MyApp.app"]) == "MyApp.app")
    }

    @Test func `should find the app in an archive whatever the case of its .app extension`() {
        #expect(AppArchive.installableApp(amongExtracted: ["MyApp.APP"]) == "MyApp.APP")
    }

    @Test func `should ignore Finder junk and dotfiles when locating the app in an archive`() {
        #expect(AppArchive.installableApp(
            amongExtracted: ["__MACOSX", ".DS_Store", "MyApp.app"]
        ) == "MyApp.app")
    }

    @Test func `should find no installable app when a zip has no .app inside`() {
        #expect(AppArchive.installableApp(amongExtracted: ["readme.txt", "assets"]) == nil)
    }

    @Test func `should find no installable app when the archive is empty`() {
        #expect(AppArchive.installableApp(amongExtracted: []) == nil)
    }

    @Test func `should refuse an archive holding two .app bundles as ambiguous`() {
        #expect(AppArchive.installableApp(
            amongExtracted: ["One.app", "Two.app"]
        ) == nil)
    }

    // MARK: declared uncompressed size (pre-flight zip-bomb check)

    @Test func `should total the uncompressed size every zip entry declares`() {
        let zip = ZipFixture.archive(declaring: [
            ("MyApp.app/Info.plist", 100), ("MyApp.app/MyApp", 200),
        ])
        #expect(AppArchive.declaredUncompressedBytes(in: zip) == 300)
    }

    @Test func `should read the declared size when the zip ends with an archive comment`() {
        let zip = ZipFixture.archive(
            declaring: [("MyApp.app/MyApp", 64)],
            comment: Data("signed by tooling".utf8)
        )
        #expect(AppArchive.declaredUncompressedBytes(in: zip) == 64)
    }

    @Test func `should declare zero bytes when the archive is empty`() {
        #expect(AppArchive.declaredUncompressedBytes(in: ZipFixture.archive(declaring: [])) == 0)
    }

    @Test func `should not read bytes as a zip when they carry no end-of-central-directory record`() {
        #expect(AppArchive.declaredUncompressedBytes(in: Data("not a zip at all".utf8)) == nil)
    }

    @Test func `should not read a zip whose central directory points outside its bytes`() {
        var zip = ZipFixture.archive(declaring: [("MyApp.app/MyApp", 64)])
        let eocd = zip.count - 22
        zip.replaceSubrange((eocd + 16)..<(eocd + 20), with: [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(AppArchive.declaredUncompressedBytes(in: zip) == nil)
    }

    @Test func `should not read a zip that claims more entries than its central directory holds`() {
        var zip = ZipFixture.archive(declaring: [("MyApp.app/MyApp", 64)])
        let eocd = zip.count - 22
        zip[eocd + 10] = 2   // claims two entries; only one exists
        #expect(AppArchive.declaredUncompressedBytes(in: zip) == nil)
    }
}
