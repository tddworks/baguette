import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies

/// What `emulator -list-avds` prints, read as the installed AVDs' names.
@Suite("AVDListing")
struct AVDListingTests {
    @Test func `should list each installed AVD by name`() {
        #expect(AVDListing.names(in: "baguette_pixel\nPixel_9_API_35\n") == ["baguette_pixel", "Pixel_9_API_35"])
    }

    @Test func `should pass over the emulator's own log lines`() {
        #expect(AVDListing.names(in: "INFO    | Storing crashdata in: /tmp/x\nbaguette_pixel\n\n") == ["baguette_pixel"])
    }
}
