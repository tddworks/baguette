import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("CleanAperture")
struct CleanApertureTests {
    @Test func `should keep the screen at the top-left of a padded picture`() {
        let aperture = CleanAperture(screen: Size(width: 1320, height: 2868), picture: Size(width: 1328, height: 2896))

        #expect(aperture == CleanAperture(width: 1320, height: 2868, horizontalOffset: -4, verticalOffset: -14))
    }

    @Test func `should crop nothing when the picture is no larger than the screen`() {
        #expect(CleanAperture(screen: Size(width: 1206, height: 2622), picture: Size(width: 1206, height: 2622)) == nil)
        #expect(CleanAperture(screen: Size(width: 1320, height: 2868), picture: Size(width: 1080, height: 2340)) == nil)
    }
}
