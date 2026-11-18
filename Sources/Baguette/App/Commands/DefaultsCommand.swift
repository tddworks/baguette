import ArgumentParser
import Foundation

/// `baguette defaults <read|write|delete> --udid <UDID> --bundle-id <id> [--suite <group>] …`
///
/// Reads and edits an installed app's persisted `UserDefaults` — its
/// standard defaults, or a named suite — with every value typed. The
/// container lookup and `defaults` spawn live in
/// `Infrastructure/Defaults/SimctlDefaults.swift`; the value types and the
/// quit / relaunch around an edit in `Domain/Defaults/`.
struct DefaultsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "defaults",
        abstract: "Read or edit an app's UserDefaults, typed, including App Group suites",
        subcommands: [Read.self, Write.self, Delete.self, Export.self, Import.self]
    )

    /// Which simulator, which app, which suite — shared by all three verbs.
    struct Target: ParsableArguments {
        @OptionGroup var device: DeviceOption

        @Option(name: .customLong("bundle-id"), help: "The app's bundle identifier")
        var bundleID: String

        @Option(help: "An App Group suite (the group identifier) instead of the app's standard defaults")
        var suite: String?

        func preferenceSuite() throws -> PreferenceSuite {
            try PreferenceSuite(bundleID: bundleID, name: suite)
        }

        func simulator() throws -> any Simulator {
            try device.simulator(for: .defaults)
        }
    }

    /// `baguette defaults read --udid <UDID> --bundle-id <id> [--suite <group>] [--key <k>] [--json]`
    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Print the app's persisted defaults and the settings it looks up but nothing stores, or one key"
        )

        @OptionGroup var target: Target

        @Option(help: "Read only this key (reports whether it is set)")
        var key: String?

        @Flag(help: "Print typed JSON instead of text")
        var json = false

        func run() async throws {
            let preferences: Preferences
            let suite: PreferenceSuite
            let lookups: PreferenceLookups?
            do {
                suite = try target.preferenceSuite()
                let defaults = try target.simulator().defaults()
                preferences = try await defaults.read(suite)
                lookups = key == nil ? try await defaults.lookups(of: suite.bundleID) : nil
            } catch let exit as ExitCode {
                throw exit
            } catch {
                log("defaults read failed: \(error)")
                throw ExitCode.failure
            }
            guard json else {
                print(Self.text(preferences, key: key, unset: lookups?.unset(in: preferences, suite: suite) ?? []))
                return
            }
            var object = key.map(preferences.json(forKey:)) ?? preferences.json(in: suite)
            if key == nil {
                object["lookups"] = PreferenceLookups.json(lookups, unsetIn: preferences, suite: suite)
            }
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
        }

        /// One `key = value (type)` line per preference, in key order;
        /// collections print as their plist fragment. Then each setting the
        /// running app looks up that nothing stores, saying where its value
        /// comes from — a registered fallback, or the app's own code.
        static func text(_ preferences: Preferences, key: String?, unset: [PreferenceLookup] = []) -> String {
            let keys = key.map { [$0] } ?? preferences.values.keys.sorted()
            let stored = keys.map { key in
                guard let value = preferences.values[key] else { return "\(key) is not set" }
                return "\(key) = \(display(value)) (\(value.typeName))"
            }
            let notSet = unset.map { lookup -> String in
                let source = lookup.registered.map { "registered \(display($0))" } ?? "the app's own default"
                let detail = [lookup.type?.wireName, source].compactMap { $0 }.joined(separator: ", ")
                return "\(lookup.key) is not set (\(detail))"
            }
            return (stored + notSet).joined(separator: "\n")
        }

        private static func display(_ value: PreferenceValue) -> String {
            switch value {
            case .bool(let flag): return "\(flag)"
            case .integer(let n): return "\(n)"
            case .real(let x): return "\(x)"
            case .string(let s): return s
            case .date, .data:
                return value.json["value"].map { "\($0)" } ?? value.xmlFragment
            case .array, .dictionary: return value.xmlFragment
            }
        }
    }

    /// How an edit treats the running app: `--relaunch` always quits it
    /// first and launches it after; `--relaunch-if-needed` does that only
    /// for a key the running app doesn't watch (an `@AppStorage` key
    /// updates in place). Neither leaves the app alone.
    struct RelaunchOption: ParsableArguments {
        @Flag(help: "Quit the app before the change and launch it after, so it starts from the new value")
        var relaunch = false

        @Flag(help: "Relaunch only if the running app wouldn't see the change: it read the key once rather than watching it")
        var relaunchIfNeeded = false

        func validate() throws {
            if relaunch && relaunchIfNeeded {
                throw ValidationError("pass --relaunch or --relaunch-if-needed, not both")
            }
        }

        var choice: Relaunch { relaunchIfNeeded ? .whenNeeded : relaunch ? .always : .never }

        /// What the log line adds after the change.
        static func said(_ relaunched: Bool, bundleID: String) -> String {
            relaunched ? " and relaunched \(bundleID)" : ""
        }
    }

    /// `baguette defaults write … --key <k> --type <type> --value <v> [--relaunch | --relaunch-if-needed]`
    struct Write: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "write",
            abstract: "Store a typed value under a key"
        )

        @OptionGroup var target: Target

        @Option(help: "The key to store under")
        var key: String

        @Option(help: ArgumentHelp(
            "The value's type: \(PreferenceType.allValueStrings.joined(separator: " | ")). "
                + "plist takes an XML fragment, for arrays and dictionaries"
        ))
        var type: PreferenceType

        @Option(help: "The value, e.g. false, 3, 1.5, 2026-01-02T03:04:05Z, base64 data, or <array>…</array>")
        var value: String

        @OptionGroup var relaunch: RelaunchOption

        func edit() throws -> PreferenceEdit {
            PreferenceEdit(
                suite: try target.preferenceSuite(),
                key: key,
                change: .set(try PreferenceValue.parse(type: type, value: value)),
                relaunch: relaunch.choice
            )
        }

        func run() async throws {
            let applied: PreferenceEdit.Applied
            do {
                let simulator = try target.simulator()
                applied = try await edit().apply(on: simulator.defaults(), apps: simulator.apps())
            } catch let exit as ExitCode {
                throw exit
            } catch {
                log("defaults write failed: \(error)")
                throw ExitCode.failure
            }
            log("Wrote \(key) for \(target.suite ?? target.bundleID)"
                + RelaunchOption.said(applied.relaunched, bundleID: target.bundleID))
        }
    }

    /// `baguette defaults delete … --key <k> [--relaunch | --relaunch-if-needed]`
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Remove a key, leaving every other preference alone"
        )

        @OptionGroup var target: Target

        @Option(help: "The key to remove")
        var key: String

        @OptionGroup var relaunch: RelaunchOption

        func edit() throws -> PreferenceEdit {
            PreferenceEdit(suite: try target.preferenceSuite(), key: key, change: .remove, relaunch: relaunch.choice)
        }

        func run() async throws {
            let applied: PreferenceEdit.Applied
            do {
                let simulator = try target.simulator()
                applied = try await edit().apply(on: simulator.defaults(), apps: simulator.apps())
            } catch let exit as ExitCode {
                throw exit
            } catch {
                log("defaults delete failed: \(error)")
                throw ExitCode.failure
            }
            log((applied.changed ? "Removed \(key)" : "\(key) was not set; nothing removed")
                + RelaunchOption.said(applied.relaunched, bundleID: target.bundleID))
        }
    }

    /// `baguette defaults export … [--key <k> …] > prefs.json`
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Print the suite's preferences as typed JSON, for `defaults import`"
        )

        @OptionGroup var target: Target

        @Option(name: .customLong("key"), help: "Export only this key (repeatable)")
        var keys: [String] = []

        func export(_ preferences: Preferences, from suite: PreferenceSuite) -> [String: Any] {
            (keys.isEmpty ? preferences : preferences.only(keys)).json(in: suite)
        }

        func run() async throws {
            let object: [String: Any]
            do {
                let suite = try target.preferenceSuite()
                object = export(try await target.simulator().defaults().read(suite), from: suite)
            } catch let exit as ExitCode {
                throw exit
            } catch {
                log("defaults export failed: \(error)")
                throw ExitCode.failure
            }
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
        }
    }

    /// `baguette defaults import … --file prefs.json [--relaunch | --relaunch-if-needed]`
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Write every value from a `defaults export` file, leaving other keys alone"
        )

        @OptionGroup var target: Target

        @Option(help: "A `defaults export` file, or a JSON map of typed values; - reads stdin")
        var file: String

        @OptionGroup var relaunch: RelaunchOption

        /// The file's values, written into the suite named on the command
        /// line — not the one the export came from, so a set saved from one
        /// app or simulator can seed another.
        func preferenceImport(from data: Data) throws -> PreferenceImport {
            PreferenceImport(
                suite: try target.preferenceSuite(),
                preferences: try Preferences(importing: data),
                relaunch: relaunch.choice
            )
        }

        func run() async throws {
            let applied: PreferenceImport.Applied
            do {
                let data = file == "-"
                    ? FileHandle.standardInput.readDataToEndOfFile()
                    : try Data(contentsOf: URL(fileURLWithPath: file))
                let restore = try preferenceImport(from: data)
                let simulator = try target.simulator()
                applied = try await restore.apply(on: simulator.defaults(), apps: simulator.apps())
            } catch let exit as ExitCode {
                throw exit
            } catch {
                log("defaults import failed: \(error)")
                throw ExitCode.failure
            }
            let written = applied.written
            log("Imported \(written) value\(written == 1 ? "" : "s") into \(target.suite ?? target.bundleID)"
                + RelaunchOption.said(applied.relaunched, bundleID: target.bundleID))
        }
    }
}

// Kept in App so Domain stays free of ArgumentParser.
extension PreferenceType: ExpressibleByArgument {
    public init?(argument: String) { self.init(wireName: argument) }
    public static var allValueStrings: [String] { allCases.map(\.wireName) }
}
