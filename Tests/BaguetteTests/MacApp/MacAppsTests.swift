import Testing
import Foundation
import Mockable
@testable import Baguette

/// Default-impl behaviour of the `MacApps` aggregate — `active`,
/// `inactive`, and `listJSON` projections that downstream call sites
/// (CLI list, serve `/mac.json`) rely on. Concrete `RunningMacApps`
/// is exercised separately via integration only; these tests use
/// `MockMacApps` configured with a synthetic `all`.
@Suite("MacApps default-impl semantics")
struct MacAppsTests {

    // Two-app fixture: TextEdit is frontmost, Finder is in the
    // background. Builds the aggregate by stubbing `all` so the
    // computed properties exercise the default extension methods.
    private func host(with apps: [(String, pid_t, String, Bool)]) -> any MacApps {
        let host = MockMacApps()
        let values = apps.map { (bid, pid, name, active) in
            MacApp(bundleID: bid, pid: pid, name: name, isActive: active, host: host)
        }
        given(host).all.willReturn(values)
        return host
    }

    @Test func `active filters apps where isActive is true`() {
        let h = host(with: [
            ("com.apple.TextEdit", 1, "TextEdit", true),
            ("com.apple.finder",   2, "Finder",   false),
        ])
        let active = h.active
        #expect(active.count == 1)
        #expect(active.first?.bundleID == "com.apple.TextEdit")
    }

    @Test func `inactive filters apps where isActive is false`() {
        let h = host(with: [
            ("com.apple.TextEdit", 1, "TextEdit", true),
            ("com.apple.finder",   2, "Finder",   false),
        ])
        let inactive = h.inactive
        #expect(inactive.count == 1)
        #expect(inactive.first?.bundleID == "com.apple.finder")
    }

    @Test func `active and inactive are disjoint and cover all`() {
        let h = host(with: [
            ("com.a", 1, "A", true),
            ("com.b", 2, "B", false),
            ("com.c", 3, "C", true),
        ])
        let active = Set(h.active.map(\.bundleID))
        let inactive = Set(h.inactive.map(\.bundleID))
        #expect(active.isDisjoint(with: inactive))
        #expect(active.union(inactive) == ["com.a", "com.b", "com.c"])
    }

    @Test func `listJSON groups active and inactive with sorted keys`() {
        let h = host(with: [
            ("com.apple.TextEdit", 1, "TextEdit", true),
            ("com.apple.finder",   2, "Finder",   false),
        ])
        let json = h.listJSON
        // sortedKeys means "active" appears before "inactive" at the
        // top level. Both bundle IDs land in their respective array.
        #expect(json.contains("\"active\""))
        #expect(json.contains("\"inactive\""))
        #expect(json.range(of: "\"active\"")!.lowerBound
            < json.range(of: "\"inactive\"")!.lowerBound)
        #expect(json.contains("com.apple.TextEdit"))
        #expect(json.contains("com.apple.finder"))
    }

    @Test func `listJSON entries carry bundleID pid name and active fields`() throws {
        let h = host(with: [
            ("com.apple.TextEdit", 4242, "TextEdit", true),
        ])
        let data = h.listJSON.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let active = dict["active"] as! [[String: Any]]
        #expect(active.count == 1)
        let entry = active[0]
        #expect(entry["bundleID"] as? String == "com.apple.TextEdit")
        #expect(entry["pid"] as? Int == 4242)
        #expect(entry["name"] as? String == "TextEdit")
        #expect(entry["active"] as? Bool == true)
    }

    @Test func `listJSON is empty arrays when no apps are running`() throws {
        let h = host(with: [])
        let data = h.listJSON.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((dict["active"]   as! [Any]).isEmpty)
        #expect((dict["inactive"] as! [Any]).isEmpty)
    }
}
