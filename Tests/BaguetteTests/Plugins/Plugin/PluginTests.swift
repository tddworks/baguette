import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

@Suite("Plugin")
struct PluginTests {

    // MARK: - namespacing

    @Test func `should qualify a command's id with its plugin's name`() throws {
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"])
        #expect(plugin.qualifiedCommandIDs == ["a11y:audit"])
    }

    @Test func `should find a command by its qualified id`() throws {
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"])
        #expect(plugin.command(qualified: "a11y:audit")?.id == "audit")
    }

    @Test func `should not find a command under another plugin's namespace or unqualified`() throws {
        // Two plugins may both contribute `reload`; the namespace is
        // what keeps them apart, so a bare or foreign prefix must miss.
        let plugin = Self.make(name: "expo", commandIDs: ["reload"])
        #expect(plugin.command(qualified: "detox:reload") == nil)
        #expect(plugin.command(qualified: "reload") == nil)
    }

    @Test func `should find no command when its id is unknown`() throws {
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"])
        #expect(plugin.command(qualified: "a11y:nope") == nil)
    }

    // MARK: - the rail icon

    @Test func `should show a plugin in the rail by the icon it names`() throws {
        let plugin = Self.make(name: "expo", commandIDs: ["reload"], icon: .wrench,
                               panelIcons: [.reload])
        #expect(plugin.railIcon == .wrench)
    }

    @Test func `should show a plugin in the rail by its first panel's icon when it names none of its own`() throws {
        // Most existing manifests predate the group icon. Rather than
        // leave them faceless in the collapsed rail, they wear the
        // glyph of the panel they lead with.
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"], panelIcons: [.accessibility, .list])
        #expect(plugin.railIcon == .accessibility)
    }

    @Test func `should show no rail icon when a plugin ships neither an icon nor a panel`() throws {
        // A command-only plugin contributes nothing to the rail, so the
        // host has no glyph to draw — it decides what to show, not us.
        let plugin = Self.make(name: "headless", commandIDs: ["run"])
        #expect(plugin.railIcon == nil)
    }

    // MARK: - the collection

    @Test func `should find an installed plugin by name`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Self.make(name: "a11y", commandIDs: ["audit"]),
            Self.make(name: "expo", commandIDs: ["reload"]),
        ])
        #expect(try plugins.plugin(named: "expo")?.id == "expo")
    }

    @Test func `should find no plugin when it is not installed`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([])
        #expect(try plugins.plugin(named: "ghost") == nil)
    }

    @Test func `should list installed plugins as JSON without exposing their run commands`() throws {
        // Shape consumed by `GET /plugins.json`. Panels carry the
        // rendering instructions; the executable behind each command
        // is deliberately absent — the browser never needs it, and
        // publishing local paths to the page is gratuitous.
        let plugins = MockPlugins()
        given(plugins).all().willReturn([Self.make(name: "a11y", commandIDs: ["audit"])])

        let json = try plugins.listJSON
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let list = try #require(parsed?["plugins"] as? [[String: Any]])

        #expect(list.count == 1)
        #expect(list[0]["name"] as? String == "a11y")
        #expect(list[0]["version"] as? String == "1.0.0")
        let commands = try #require(list[0]["commands"] as? [[String: Any]])
        #expect(commands[0]["id"] as? String == "a11y:audit")
        #expect(commands[0]["title"] as? String == "Run audit")
        #expect(commands[0]["run"] == nil)
    }

    @Test func `should list the icon that represents each plugin`() throws {
        // The rail collapses a plugin to one entry, and the browser
        // must not have to re-derive which glyph that is — the host
        // resolves the fallback and states the answer.
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Self.make(name: "expo", commandIDs: ["reload"], icon: .wrench, panelIcons: [.reload]),
            Self.make(name: "a11y", commandIDs: ["audit"], panelIcons: [.accessibility]),
            Self.make(name: "headless", commandIDs: ["run"]),
        ])

        let parsed = try JSONSerialization.jsonObject(with: Data(try plugins.listJSON.utf8))
        let list = try #require((parsed as? [String: Any])?["plugins"] as? [[String: Any]])

        #expect(list[0]["icon"] as? String == "wrench")
        #expect(list[1]["icon"] as? String == "accessibility")
        #expect(list[2]["icon"] == nil)
    }

    // MARK: - helpers

    static func make(
        name: String,
        commandIDs: [String],
        icon: PluginIcon? = nil,
        panelIcons: [PluginIcon] = []
    ) -> Plugin {
        Plugin(
            root: URL(fileURLWithPath: "/tmp/plugins/\(name)"),
            manifest: PluginManifest(
                name: name,
                version: "1.0.0",
                apiVersion: 1,
                icon: icon,
                commands: commandIDs.map {
                    PluginCommand(id: $0, title: "Run audit", run: ["node", "bin/\($0).js"])
                },
                panels: panelIcons.enumerated().map { index, panelIcon in
                    PluginPanel(
                        id: "panel\(index)",
                        title: "Panel \(index)",
                        icon: panelIcon,
                        body: .list(ListBody(source: commandIDs.first ?? ""))
                    )
                }
            )
        )
    }
}
