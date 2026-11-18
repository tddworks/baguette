import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// `rowAction: "run"` — a row that invokes one of its own plugin's
/// commands when clicked.
///
/// The other three actions are things the *host* does with a row's data
/// (box it, tap it, copy it). `run` hands control back to the plugin,
/// which is what makes a panel interactive rather than a report: a
/// settings list can offer "Dark" and have picking it actually do
/// something, then re-render from the command's fresh answer.
///
/// A row therefore has to say **which** command and **with what**, so
/// rows gain `run` and `args`.
@Suite("Plugin run action")
struct PluginRunActionTests {

    // MARK: - the manifest side

    @Test func `should let a panel declare the run row action`() throws {
        let body = try PanelBody.parsing(
            dict: ["kind": "list", "source": "settings", "rowAction": "run"],
            declaredCommands: ["settings"]
        )
        #expect(body == .list(ListBody(source: "settings", rowAction: .run)))
    }

    @Test func `should reject an unknown row action`() {
        #expect(throws: PluginManifestError.unknownRowAction(name: "detonate")) {
            _ = try PanelBody.parsing(
                dict: ["kind": "list", "source": "settings", "rowAction": "detonate"],
                declaredCommands: ["settings"]
            )
        }
    }

    // MARK: - the row side

    @Test func `should let a row name the command to run and the arguments to run it with`() throws {
        let row = try ResultRow.parsing(
            dict: [
                "title": "Dark",
                "run": "set",
                "args": ["appearance": "dark"],
            ],
            index: 0
        )
        #expect(row.run == "set")
        #expect(row.args?["appearance"] as? String == "dark")
    }

    @Test func `should carry no command or arguments when a row names no run`() throws {
        let row = try ResultRow.parsing(dict: ["title": "Button has no label"], index: 0)
        #expect(row.run == nil)
        #expect(row.args == nil)
    }

    @Test func `should reject a row's args when it names no command to run`() {
        // Arguments to nothing is a manifest bug, and silently dropping
        // them would make the row look clickable and do nothing.
        #expect(throws: PluginResultError.argsWithoutRun(index: 0)) {
            _ = try ResultRow.parsing(
                dict: ["title": "Dark", "args": ["appearance": "dark"]], index: 0
            )
        }
    }

    @Test func `should reject a row's run when it is not a command id`() {
        #expect(throws: PluginResultError.malformedRun(index: 2)) {
            _ = try ResultRow.parsing(dict: ["title": "Dark", "run": 42], index: 2)
        }
    }

    @Test func `should reject a row's args when they are a bare value rather than an object`() {
        #expect(throws: PluginResultError.malformedArgs(index: 1)) {
            _ = try ResultRow.parsing(
                dict: ["title": "Dark", "run": "set", "args": "appearance=dark"], index: 1
            )
        }
    }

    // MARK: - reaching the command

    @Test func `should hand a row's args to the command in the context it reads on stdin`() throws {
        // The command already receives its context as JSON on stdin;
        // arguments ride the same channel rather than inventing a second
        // one. Env vars would mean flattening a nested object into
        // strings, which loses types the plugin just sent.
        let context = PluginDispatch.Context(
            serverURL: "http://127.0.0.1:8421",
            udid: "U",
            token: "tok",
            args: ["appearance": "dark"]
        )
        let json = PluginDispatch.contextJSON("a11y:set", context)
        let parsed = try #require(
            JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        let args = try #require(parsed["args"] as? [String: Any])
        #expect(args["appearance"] as? String == "dark")
        #expect(parsed["command"] as? String == "a11y:set")
        #expect(parsed["udid"] as? String == "U")
    }

    @Test func `should hand the command a well-formed context with no args when invoked without any`() throws {
        // Every existing plugin is in this case — the field is absent
        // rather than an empty object it would have to special-case.
        let context = PluginDispatch.Context(
            serverURL: "http://127.0.0.1:8421", udid: "U", token: "tok"
        )
        let json = PluginDispatch.contextJSON("a11y:audit", context)
        let parsed = try #require(
            JSONSerialization.jsonObject(with: json) as? [String: Any]
        )
        #expect(parsed["args"] == nil)
    }

    @Test func `should keep a row's args when the context's token is swapped for a per-invocation grant`() async throws {
        // Dispatch re-issues the context with a scoped token before
        // spawning. That rewrite dropped `args` on the first cut — the
        // panel rendered, the click posted, and nothing happened. The
        // command must receive both the grant *and* the arguments.
        let grants = PluginGrants()
        let seen = SeenStdin()
        _ = await PluginDispatch.run(
            qualifiedCommand: "a11y:display",
            context: PluginDispatch.Context(
                serverURL: "http://127.0.0.1:8421",
                udid: "U",
                token: "",
                args: ["appearance": "dark"]
            ),
            plugins: Self.plugins(),
            grants: grants,
            subprocess: { Self.subprocess(recording: seen) }
        )

        let stdin = try #require(seen.data)
        let parsed = try #require(JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let args = try #require(parsed["args"] as? [String: Any])
        #expect(args["appearance"] as? String == "dark")
        // And the token is the issued grant, not the empty one we passed.
        #expect((parsed["token"] as? String)?.isEmpty == false)
    }

    /// Captures the context JSON written to the child's stdin.
    final class SeenStdin: @unchecked Sendable {
        var data: Data?
    }

    static func plugins() -> MockPlugins {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(
                root: URL(fileURLWithPath: "/tmp/plugins/a11y"),
                manifest: PluginManifest(
                    name: "a11y", version: "1.1.0", apiVersion: 1,
                    capabilities: [.interface],
                    commands: [PluginCommand(id: "display", title: "Display", run: ["true"])]
                )
            )
        ])
        return plugins
    }

    static func subprocess(recording seen: SeenStdin) -> MockSubprocess {
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, _, _, _, stdin, onBytes, onExit in
            seen.data = stdin
            onBytes(Data(#"{"ok":true}"#.utf8))
            onExit(0)
        }
        given(sub).terminate().willReturn()
        return sub
    }

    // MARK: - the route side

    @Test func `should read the command's args off the run route's request body`() {
        #expect(
            Server.parseCommandArgs(body: #"{"args":{"appearance":"dark"}}"#)?["appearance"]
                as? String == "dark"
        )
    }

    @Test func `should find no args when the run route's request body is empty, bare or not JSON`() {
        // The browser posts bodiless for a plain panel open, and that
        // must stay a valid invocation.
        #expect(Server.parseCommandArgs(body: "") == nil)
        #expect(Server.parseCommandArgs(body: "{}") == nil)
        #expect(Server.parseCommandArgs(body: "not json") == nil)
    }
}
