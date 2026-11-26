import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// What a plugin says about itself — the contents of its
/// `baguette-plugin.json`. One value describes one installed plugin:
/// who it is, which contract it was written against, and what it
/// contributes to the UI.
///
/// The manifest is the *declaration* half of the plugin contract. It
/// carries no executable code, so baguette can read it, show the user
/// what a plugin would add, and decide whether to render anything —
/// all without running a single line the plugin shipped. Code only
/// runs when the user activates a contribution (see `PluginCommand`).
///
/// Parsing is a pure function over bytes, which is what keeps the
/// plugin system unit-testable: no filesystem, no subprocess, no
/// dynamic loading anywhere in this type.
struct PluginManifest: Equatable, Sendable {

    /// The manifest contract this build of baguette understands.
    /// A manifest declaring a *newer* number is refused outright
    /// rather than parsed leniently — see `parsing(json:)`.
    static let supportedAPIVersion = 1

    /// What a manifest that omits `apiVersion` is taken to mean.
    ///
    /// **Pinned at 1 forever, deliberately decoupled from
    /// `supportedAPIVersion`.** The default is a statement about what
    /// manifests written before the field existed *meant*, not about
    /// what this build can read. Tying it to the ceiling would mean the
    /// day that becomes 2, every such manifest is silently reinterpreted
    /// as a v2 manifest — and misparsed wherever v2 changed a meaning.
    static let defaultAPIVersion = 1

    let name: String
    let version: String
    let apiVersion: Int
    /// One-line summary shown by `baguette plugin list` / `show`.
    /// `nil` when the manifest omits it.
    let description: String?
    /// The glyph that stands for the plugin as a whole. A plugin owns
    /// one rail entry no matter how many panels it contributes, so it
    /// gets to name its own face rather than wearing an arbitrary
    /// panel's. `nil` when the manifest omits it — see `Plugin.railIcon`
    /// for what the host draws then.
    let icon: PluginIcon?
    /// What this plugin may ask baguette to do. Empty means nothing —
    /// least privilege by default.
    let capabilities: [PluginCapability]
    let commands: [PluginCommand]
    let panels: [PluginPanel]
    /// Problems that didn't stop the manifest parsing — an icon name
    /// this build doesn't know, so far. Carried on the value rather
    /// than thrown so an older baguette still renders a newer plugin,
    /// while `baguette plugin validate` can still tell an author they
    /// typed `wrentch`.
    let warnings: [PluginManifestWarning]

    init(
        name: String,
        version: String,
        apiVersion: Int,
        description: String? = nil,
        icon: PluginIcon? = nil,
        capabilities: [PluginCapability] = [],
        commands: [PluginCommand] = [],
        panels: [PluginPanel] = [],
        warnings: [PluginManifestWarning] = []
    ) {
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.description = description
        self.icon = icon
        self.capabilities = capabilities
        self.commands = commands
        self.panels = panels
        self.warnings = warnings
    }

    // MARK: - parsing

    /// Parse a `baguette-plugin.json` payload.
    ///
    /// The `apiVersion` gate runs **before** any field is read. A
    /// manifest from the future may use shapes this build cannot
    /// interpret, so refusing it wholesale is honest; parsing what we
    /// recognise and dropping the rest would silently give the user a
    /// half-working plugin.
    static func parsing(json data: Data) throws -> PluginManifest {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PluginManifestError.malformedJSON
        }
        guard let dict = raw as? [String: Any] else {
            throw PluginManifestError.malformedJSON
        }

        let apiVersion = dict["apiVersion"] as? Int ?? defaultAPIVersion
        guard apiVersion <= supportedAPIVersion else {
            throw PluginManifestError.unsupportedAPIVersion(
                declared: apiVersion, supported: supportedAPIVersion
            )
        }

        guard let name = dict["name"] as? String, !name.isEmpty else {
            throw PluginManifestError.missingName
        }
        guard let version = dict["version"] as? String, !version.isEmpty else {
            throw PluginManifestError.missingVersion
        }

        var warnings: [PluginManifestWarning] = []

        // Resolved against the shipped set, never passed through: this
        // string would otherwise land in the DOM of the very origin
        // `isTrustedBrowserRequest` defends. Resolving to a fallback
        // keeps that guarantee while letting a plugin that names a
        // future glyph still work here.
        //
        // Absent is legal and silent — `Plugin.railIcon` borrows the
        // first panel's. Only a name we were *given* and can't place
        // earns a warning.
        var icon: PluginIcon?
        if let rawIcon = dict["icon"] as? String {
            let resolved = PluginIcon.resolving(rawIcon)
            icon = resolved.icon
            if let warning = resolved.warning { warnings.append(warning) }
        }

        let capabilities = try (dict["capabilities"] as? [String] ?? []).map { raw in
            guard let capability = PluginCapability(rawValue: raw) else {
                throw PluginManifestError.unknownCapability(name: raw)
            }
            return capability
        }

        let contributes = dict["contributes"] as? [String: Any] ?? [:]

        // Commands parse first: a panel body names the command whose
        // output fills it, and we validate that reference here rather
        // than discovering the typo on the user's first click.
        let commandDicts = contributes["commands"] as? [[String: Any]] ?? []
        let commands = try commandDicts.map(PluginCommand.parsing(dict:))
        let declaredCommands = Set(commands.map(\.id))

        let panelDicts = contributes["panels"] as? [[String: Any]] ?? []
        let panels = try panelDicts.map {
            try PluginPanel.parsing(
                dict: $0, declaredCommands: declaredCommands, warnings: &warnings
            )
        }

        return PluginManifest(
            name: name,
            version: version,
            apiVersion: apiVersion,
            description: dict["description"] as? String,
            icon: icon,
            capabilities: capabilities,
            commands: commands,
            panels: panels,
            warnings: warnings
        )
    }
}

/// Something worth telling the author about that isn't fatal.
///
/// The distinction from `PluginManifestError` is whether the plugin can
/// still work: a missing `name` leaves nothing to install, but a glyph
/// we don't recognise leaves everything working and one picture
/// substituted. Warnings surface through `baguette plugin validate`.
enum PluginManifestWarning: Equatable, Sendable, CustomStringConvertible {
    case unknownIcon(name: String)

    var description: String {
        switch self {
        case .unknownIcon(let name):
            return """
                unknown icon \"\(name)\" — showing the default glyph instead; \
                use one of: \(PluginIcon.allCases.map(\.rawValue).joined(separator: ", "))
                """
        }
    }
}

/// Why a `baguette-plugin.json` couldn't be read. Every case names
/// something the plugin author can fix, because these surface through
/// `baguette plugin validate` as authoring feedback.
enum PluginManifestError: Error, Equatable, CustomStringConvertible {
    case malformedJSON
    case missingName
    case missingVersion
    case missingCommandID
    case emptyCommandRun(id: String)
    case unsupportedAPIVersion(declared: Int, supported: Int)
    case unknownCondition(expression: String)
    case unknownPanelBody(kind: String)
    case unknownRowAction(name: String)
    case unknownCommandSource(id: String)
    case unknownCapability(name: String)
    case missingPromptArg
    case unknownRowControl(name: String)
    case missingControlArg

    var description: String {
        switch self {
        case .malformedJSON:
            return "baguette-plugin.json is not a JSON object"
        case .missingName:
            return "manifest is missing a non-empty \"name\""
        case .missingVersion:
            return "manifest is missing a non-empty \"version\""
        case .missingCommandID:
            return "a contributed command is missing a non-empty \"id\""
        case .emptyCommandRun(let id):
            return "command \"\(id)\" has an empty \"run\" — nothing to execute"
        case .unsupportedAPIVersion(let declared, let supported):
            return """
                manifest declares apiVersion \(declared); this baguette \
                supports up to \(supported) — upgrade baguette
                """
        case .unknownCondition(let expression):
            return """
                unknown \"when\" condition \"\(expression)\" — use one of: \
                \(PluginCondition.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .unknownPanelBody(let kind):
            return "unknown panel body kind \"\(kind)\" — this baguette renders: list"
        case .unknownRowAction(let name):
            return """
                unknown rowAction \"\(name)\" — use one of: \
                \(RowAction.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .unknownCommandSource(let id):
            return "panel body names command \"\(id)\", which this plugin does not contribute"
        case .missingPromptArg:
            return """
                a panel's "prompt" is missing a non-empty "arg" — without it \
                the typed text has no key to arrive under
                """
        case .unknownRowControl(let name):
            return """
                unknown control kind \"\(name)\" — use one of: \
                \(RowControl.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .missingControlArg:
            return """
                a panel's "control" is missing a non-empty "arg" — without it \
                the ticked rows have no key to arrive under
                """
        case .unknownCapability(let name):
            return """
                unknown capability \"\(name)\" — use one of: \
                \(PluginCapability.allCases.map(\.rawValue).joined(separator: ", "))
                """
        }
    }
}
