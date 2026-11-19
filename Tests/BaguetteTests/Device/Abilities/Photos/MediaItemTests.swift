import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `MediaItem` — the thing the user means when
/// they drag a photo or clip onto a device and think "add this to my
/// camera roll." `MediaItem.at(_:)` classifies by extension (no disk
/// access); `addMediaArguments` projects the argv tail for
/// `xcrun simctl addmedia <udid> <path>`.
@Suite("MediaItem")
struct MediaItemTests {

    @Test func `should treat a file as media when it has a common image extension`() {
        for ext in ["png", "jpg", "jpeg", "gif", "heic", "heif"] {
            let url = URL(fileURLWithPath: "/tmp/shot.\(ext)")
            #expect(MediaItem.at(url) == MediaItem(path: url))
        }
    }

    @Test func `should treat a file as media when it has a common video extension`() {
        for ext in ["mov", "mp4", "m4v"] {
            let url = URL(fileURLWithPath: "/tmp/clip.\(ext)")
            #expect(MediaItem.at(url) == MediaItem(path: url))
        }
    }

    @Test func `should recognise a media extension regardless of letter case`() {
        let url = URL(fileURLWithPath: "/tmp/shot.PNG")
        #expect(MediaItem.at(url) == MediaItem(path: url))
    }

    @Test func `should not treat an app as media`() {
        #expect(MediaItem.at(URL(fileURLWithPath: "/tmp/MyApp.ipa")) == nil)
    }

    @Test func `should not treat a generic document as media`() {
        #expect(MediaItem.at(URL(fileURLWithPath: "/tmp/notes.pdf")) == nil)
    }

    @Test func `should hand simctl addmedia the udid and the media path`() {
        let media = MediaItem(path: URL(fileURLWithPath: "/tmp/My Clip.mov"))
        #expect(media.addMediaArguments(udid: "U") == ["simctl", "addmedia", "U", "/tmp/My Clip.mov"])
    }

    @Test func `should add media inside the device's custom device set when it lives in one`() {
        let media = MediaItem(path: URL(fileURLWithPath: "/tmp/My Clip.mov"))
        #expect(media.addMediaArguments(udid: "U", deviceSetPath: "/custom set")
            == ["simctl", "--set", "/custom set", "addmedia", "U", "/tmp/My Clip.mov"])
    }
}
