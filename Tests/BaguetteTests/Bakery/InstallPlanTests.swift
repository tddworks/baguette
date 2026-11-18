import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("InstallPlan")
struct InstallPlanTests {

    let twoPlugin = BakeryMenu(
        name: "acme/tools", description: nil,
        entries: [
            BakeryMenu.Entry(name: "a11y", path: "plugins/a11y"),
            BakeryMenu.Entry(name: "expo", path: "tools/expo"),
        ]
    )
    let onePlugin = BakeryMenu(
        name: "solo", description: nil,
        entries: [BakeryMenu.Entry(name: "hello", path: ".")]
    )

    // MARK: - resolving which plugin

    @Test func `should install just the plugin a reference names`() throws {
        let ref = try BakeryRef.parse("acme/tools/expo")
        let plan = try InstallPlan.resolve(ref: ref, requested: nil, menu: twoPlugin)
        #expect(plan.map(\.name) == ["expo"])
        #expect(plan.first?.path == "tools/expo")
    }

    @Test func `should let an explicitly requested name win over the reference`() throws {
        // `plugin install a11y` from a bakery already added — the ref
        // is the bakery, the requested name picks the plugin.
        let ref = try BakeryRef.parse("acme/tools")
        let plan = try InstallPlan.resolve(ref: ref, requested: "a11y", menu: twoPlugin)
        #expect(plan.map(\.name) == ["a11y"])
    }

    @Test func `should install the only plugin of a single-plugin bakery without a name`() throws {
        let ref = try BakeryRef.parse("acme/solo")
        let plan = try InstallPlan.resolve(ref: ref, requested: nil, menu: onePlugin)
        #expect(plan.map(\.name) == ["hello"])
    }

    // MARK: - errors

    @Test func `should reject a bare reference to a multi-plugin bakery as ambiguous`() throws {
        // Don't silently install all of them, and don't pick one —
        // make the user say which, naming the choices.
        let ref = try BakeryRef.parse("acme/tools")
        #expect(throws: InstallPlanError.ambiguous(available: ["a11y", "expo"])) {
            try InstallPlan.resolve(ref: ref, requested: nil, menu: twoPlugin)
        }
    }

    @Test func `should reject a requested name the bakery doesn't offer`() throws {
        let ref = try BakeryRef.parse("acme/tools")
        #expect(throws: InstallPlanError.notOffered(name: "ghost", available: ["a11y", "expo"])) {
            try InstallPlan.resolve(ref: ref, requested: "ghost", menu: twoPlugin)
        }
    }

    @Test func `should reject a referenced plugin the bakery doesn't offer`() throws {
        let ref = try BakeryRef.parse("acme/tools/ghost")
        #expect(throws: InstallPlanError.notOffered(name: "ghost", available: ["a11y", "expo"])) {
            try InstallPlan.resolve(ref: ref, requested: nil, menu: twoPlugin)
        }
    }
}
