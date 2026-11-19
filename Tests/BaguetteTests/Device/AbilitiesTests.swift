import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("Abilities")
struct AbilitiesTests {
    @Test func `should refuse an ability the device never registered`() {
        var table = Abilities(device: "iPhone 18 Pro Max")
        table.register(.shake) { MockShake() }

        #expect(throws: DeviceError.unable(ability: "location", device: "iPhone 18 Pro Max")) {
            try table.require(.location)
        }
    }

    @Test func `should hand back the role registered for an ability`() throws {
        let location = MockLocation()
        var table = Abilities(device: "iPhone 17 Pro")
        table.register(.location) { location }

        let found = try table.require(.location)

        #expect(found as AnyObject === location)
    }

    @Test func `should build a fresh role each time an ability is asked for`() throws {
        var table = Abilities(device: "iPhone 17 Pro")
        table.register(.location) { MockLocation() }

        let first = try table.require(.location)
        let second = try table.require(.location)

        #expect(first as AnyObject !== second as AnyObject)
    }

    @Test func `should name the abilities in the order they were registered`() {
        var table = Abilities(device: "iPhone 17 Pro")
        table.register(.shake) { MockShake() }
        table.register(.location) { MockLocation() }

        #expect(table.names == ["shake", "location"])
    }

    @Test func `should name an ability once when it is registered twice`() throws {
        let second = MockLocation()
        var table = Abilities(device: "iPhone 17 Pro")
        table.register(.location) { MockLocation() }
        table.register(.location) { second }

        #expect(table.names == ["location"])
        #expect(try table.require(.location) as AnyObject === second)
    }
}
