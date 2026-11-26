import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// A side panel a plugin adds to focus mode, described entirely as
/// data. The host owns every pixel: it picks the glyph from `icon`,
/// renders the card chrome, and fills `body` from the named command's
/// output. The plugin supplies no markup, no CSS and no script.
///
/// That constraint is the whole security posture of v1. `sim.html` is
/// the origin `Server.isTrustedBrowserRequest` spends ~70 lines
/// defending; anything a plugin could inject there would be
/// same-origin and could drive the simulator silently. Keeping panels
/// declarative means untrusted manifest text never becomes markup.
struct PluginPanel: Equatable, Sendable {
    let id: String
    let title: String
    let icon: PluginIcon
    /// When the panel is offered. `nil` means always.
    let when: PluginCondition?
    let body: PanelBody

    init(id: String, title: String, icon: PluginIcon, when: PluginCondition? = nil, body: PanelBody) {
        self.id = id
        self.title = title
        self.icon = icon
        self.when = when
        self.body = body
    }

    // MARK: - parsing

    /// `declaredCommands` are the ids this plugin contributes; a body
    /// naming anything else is a typo the author should hear about at
    /// validate time rather than on first click.
    static func parsing(
        dict: [String: Any],
        declaredCommands: Set<String>,
        warnings: inout [PluginManifestWarning]
    ) throws -> PluginPanel {
        let id = dict["id"] as? String ?? ""

        let resolved = PluginIcon.resolving(dict["icon"] as? String ?? "")
        let icon = resolved.icon
        if let warning = resolved.warning { warnings.append(warning) }

        var condition: PluginCondition?
        if let rawWhen = dict["when"] as? String {
            guard let parsed = PluginCondition(rawValue: rawWhen) else {
                throw PluginManifestError.unknownCondition(expression: rawWhen)
            }
            condition = parsed
        }

        let body = try PanelBody.parsing(
            dict: dict["body"] as? [String: Any] ?? [:],
            declaredCommands: declaredCommands
        )

        return PluginPanel(
            id: id,
            title: dict["title"] as? String ?? id,
            icon: icon,
            when: condition,
            body: body
        )
    }
}

/// What fills a panel. One case in v1 — deliberately.
///
/// The known ceiling of a declarative UI is that every new widget kind
/// costs a baguette release. That's the accepted trade for not running
/// plugin code in the page. When a real plugin needs something a list
/// can't express, the successor is a sandboxed-iframe `webview` case
/// behind an `apiVersion` bump — which is why an unrecognised kind
/// throws rather than rendering an empty card.
enum PanelBody: Equatable, Sendable {
    /// Rows come from running the plugin's `source` command and
    /// reading the `rows` array off its JSON answer.
    case list(ListBody)

    static func parsing(dict: [String: Any], declaredCommands: Set<String>) throws -> PanelBody {
        let kind = dict["kind"] as? String ?? ""
        guard kind == "list" else {
            throw PluginManifestError.unknownPanelBody(kind: kind)
        }
        return .list(try ListBody.parsing(dict: dict, declaredCommands: declaredCommands))
    }
}

/// Everything a `kind: "list"` body declares.
///
/// A struct rather than the enum case's associated values, because every
/// optional field added here would otherwise be a source break at every
/// construction site — Swift can't default an associated value. `prompt`
/// cost four unrelated test edits to add that way; `control` cost none.
/// The panel contract grows by *addition*, so the shape it grows into
/// has to make addition free.
struct ListBody: Equatable, Sendable {
    /// The command whose `rows` fill the panel.
    let source: String
    /// What clicking a row does. `nil` leaves rows inert.
    let rowAction: RowAction?
    /// A text field above the rows. `nil` for a read-only report.
    let prompt: PanelPrompt?
    /// Tickable controls on the rows. `nil` for a plain list.
    let control: PanelControl?

    init(
        source: String,
        rowAction: RowAction? = nil,
        prompt: PanelPrompt? = nil,
        control: PanelControl? = nil
    ) {
        self.source = source
        self.rowAction = rowAction
        self.prompt = prompt
        self.control = control
    }

    static func parsing(dict: [String: Any], declaredCommands: Set<String>) throws -> ListBody {
        let source = dict["source"] as? String ?? ""
        guard declaredCommands.contains(source) else {
            throw PluginManifestError.unknownCommandSource(id: source)
        }

        var rowAction: RowAction?
        if let raw = dict["rowAction"] as? String {
            guard let parsed = RowAction(rawValue: raw) else {
                throw PluginManifestError.unknownRowAction(name: raw)
            }
            rowAction = parsed
        }

        return ListBody(
            source: source,
            rowAction: rowAction,
            prompt: try (dict["prompt"] as? [String: Any]).map(PanelPrompt.parsing(dict:)),
            control: try (dict["control"] as? [String: Any]).map(PanelControl.parsing(dict:))
        )
    }
}

/// Tickable controls on a panel's rows, and what submitting them means.
///
/// Before this, a plugin wanting a settings list wrote its state into
/// the row *title* — `display.py` shipped `"● Light"` / `"○ Dark"` —
/// which is a plugin drawing a control glyph inside a string, in a page
/// whose whole premise is that the host owns every pixel. Escaping made
/// it safe, not right: the host couldn't style it, a screen reader read
/// a bullet, and "which one is on" was unreadable to anything but a
/// human eye.
///
/// So state moves onto the row (`ResultRow.state`) and the *drawing*
/// moves here. The plugin says what's on; baguette says what on looks
/// like.
///
/// Ticking is **local** — it costs no subprocess. The panel accumulates
/// ticks and sends them together when the submit button is pressed,
/// which is the trade this makes deliberately: one child process per
/// *batch* instead of one per tick, at the price of rows briefly showing
/// state the device hasn't confirmed. The host marks those rows pending
/// rather than letting them look settled, because a control that lies
/// about the device is worse than one that's slow.
struct PanelControl: Equatable, Sendable {
    /// Which glyph family the host draws. Purely cosmetic: grouping is
    /// the plugin's business, since it re-renders the whole panel from
    /// its own answer after every submit.
    let kind: RowControl
    /// The key the ticked rows' `value`s are submitted under, i.e. the
    /// command sees `{"args": {"<arg>": ["camera", "mic"]}}`.
    ///
    /// **Always an array**, including for `radio`, which yields one
    /// element. One shape means a plugin has one branch to write rather
    /// than a scalar case it discovers by reading the docs twice.
    let arg: String
    /// The submit button's label.
    let submit: String

    init(kind: RowControl, arg: String, submit: String = "Apply") {
        self.kind = kind
        self.arg = arg
        self.submit = submit
    }

    static func parsing(dict: [String: Any]) throws -> PanelControl {
        let rawKind = dict["kind"] as? String ?? ""
        guard let kind = RowControl(rawValue: rawKind) else {
            throw PluginManifestError.unknownRowControl(name: rawKind)
        }
        guard let arg = dict["arg"] as? String, !arg.isEmpty else {
            throw PluginManifestError.missingControlArg
        }
        return PanelControl(kind: kind, arg: arg, submit: dict["submit"] as? String ?? "Apply")
    }
}

/// The control families baguette draws. A closed set for the same
/// reason `PluginIcon` is one: the name reaches a protected page.
///
/// Unlike an icon, an unknown one **throws** rather than degrading —
/// a checkbox silently drawn as a switch would misrepresent whether
/// ticking two rows at once is allowed, and that's a lie about
/// behaviour rather than a substituted picture.
enum RowControl: String, Equatable, Sendable, CaseIterable {
    /// Independent on/off. Several may be on at once.
    case `switch`
    /// Many-of-many, in a set that belongs together.
    case checkbox
    /// One-of-many; the host clears the others when one is ticked.
    case radio
}

/// A text field above a panel's rows, and what submitting it means.
///
/// Every panel before this one was a report: the host ran a command and
/// drew what came back. Some tools need the opposite direction — a deep
/// link is interesting precisely because nobody has typed it yet — and a
/// list of rows has nowhere to put a value that doesn't exist.
///
/// Submitting invokes the panel's **own** `source` command with the
/// typed text under `arg`, which is exactly the path `rowAction: "run"`
/// already takes. So this adds a widget, not an execution model: still
/// one command per panel, still an HTTP call to the same endpoint the
/// panel opens with, still no plugin code in the page.
///
/// The field is optional and additive on purpose. A baguette that
/// predates it ignores the key and renders the plain list, which for a
/// well-written plugin is a working panel with one affordance missing —
/// so `apiVersion` doesn't move.
struct PanelPrompt: Equatable, Sendable {
    /// The key the typed text is submitted under, i.e. the command sees
    /// `{"args": {"<arg>": "<typed>"}}`. Required: a field that
    /// submitted into nowhere would look like a working control and do
    /// nothing, so a manifest without it is refused rather than drawn.
    let arg: String
    /// Greyed hint inside the empty field. `nil` leaves it blank.
    let placeholder: String?
    /// The submit button's label.
    let submit: String
    /// Whether typing also filters the rows already on screen.
    ///
    /// A command is a subprocess with a bounded budget, so re-running it
    /// per keystroke is the wrong shape — but the rows it *already*
    /// returned are right there, and narrowing them locally gives back
    /// the feel of completion for the price of a string comparison.
    let filter: Bool
    /// Whether the field finishes the word for you: the rest of the best
    /// candidate drawn greyed after the caret, accepted with `Tab` or
    /// `→`. A list you have to point at is slower than a bar that
    /// completes.
    let complete: Bool
    /// Whether submissions are remembered for `↑` / `↓`.
    ///
    /// Kept by the browser, per panel. It's a convenience for the person
    /// typing, not state the plugin owns — so it doesn't ride the wire,
    /// and a plugin never sees what you typed before.
    let history: Bool

    init(
        arg: String,
        placeholder: String? = nil,
        submit: String = "Run",
        filter: Bool = false,
        complete: Bool = false,
        history: Bool = false
    ) {
        self.arg = arg
        self.placeholder = placeholder
        self.submit = submit
        self.filter = filter
        self.complete = complete
        self.history = history
    }

    static func parsing(dict: [String: Any]) throws -> PanelPrompt {
        guard let arg = dict["arg"] as? String, !arg.isEmpty else {
            throw PluginManifestError.missingPromptArg
        }
        return PanelPrompt(
            arg: arg,
            placeholder: dict["placeholder"] as? String,
            // A label is chrome, not meaning — default rather than
            // demand one, the way `title` already falls back to `id`.
            submit: dict["submit"] as? String ?? "Run",
            filter: dict["filter"] as? Bool ?? false,
            complete: dict["complete"] as? Bool ?? false,
            history: dict["history"] as? Bool ?? false
        )
    }
}

/// What clicking a row does. Each maps to something the host already
/// knows how to do, using the row's own `frame` (device points, the
/// same space as gesture coordinates — so no conversion).
enum RowAction: String, Equatable, Sendable, CaseIterable {
    /// Paint the AX-inspector box over the row's frame.
    case highlight
    /// Dispatch a tap at the centre of the row's frame.
    case tap
    /// Copy the row's `copy` string to the clipboard.
    case copy
    /// Invoke the command named by the row's `run`, passing its `args`,
    /// and re-render the panel from the answer.
    ///
    /// The other three are things the *host* does with a row's data.
    /// This one hands control back to the plugin, which is what turns a
    /// panel from a report into something you can operate: a settings
    /// list can offer "Dark" and have picking it actually apply.
    /// Still no plugin code in the page — the click is an HTTP call to
    /// the same command endpoint the panel already opens with.
    case run
    /// Put the row's `fill` text into the panel's own `prompt`, focus
    /// it, and leave the caret at the end.
    ///
    /// The others all *act* on a row. This one hands it to the field
    /// above, which is what a list of suggestions under a text box has
    /// always meant. The deep-link panel named it: clicking `account://`
    /// used to open a bare scheme with no path, when what anyone wants
    /// is that scheme in the box, ready for the rest of the URL. It
    /// turns a list from a launcher into completion.
    case fill
}

/// When a contribution is offered. A closed set, evaluated by the host
/// against state it already tracks — not an expression language.
enum PluginCondition: String, Equatable, Sendable, CaseIterable {
    case simulatorBooted = "simulator.booted"
}

/// The glyphs baguette ships. Plugins name one; they never supply
/// markup, because a manifest is untrusted text destined for the DOM
/// and inline SVG in that position is a script-injection vector.
///
/// Adding a case is a host release. That's the cost of the closed set,
/// and it's the point.
///
/// A name this build doesn't know **degrades to `puzzle`** rather than
/// refusing the manifest — see `resolving(_:)`. The closed set is here
/// to stop untrusted text reaching the DOM, and a fallback satisfies
/// that completely: the author's string is never rendered either way.
/// Killing a whole plugin over a glyph would be a disproportionate
/// answer, and it would make every new icon a breaking change for every
/// baguette already installed.
enum PluginIcon: String, Equatable, Sendable, CaseIterable {
    case accessibility
    case reload
    case link
    case list
    case bell
    case wrench
    case lock
    case globe
    case camera
    case clock
    case document
    case play
    /// The plugin system's own emblem, and what an unrecognised or
    /// missing name resolves to. The rail already wears it for a plugin
    /// that names no icon at all, so a fallback looks deliberate rather
    /// than broken.
    case puzzle

    /// Resolve an authored name, falling back to `puzzle`.
    ///
    /// Returns the warning alongside so the caller can carry it to
    /// `plugin validate`: degrading must not mean going quiet, or a
    /// plain typo becomes invisible.
    static func resolving(_ raw: String) -> (icon: PluginIcon, warning: PluginManifestWarning?) {
        guard let known = PluginIcon(rawValue: raw) else {
            return (.puzzle, .unknownIcon(name: raw))
        }
        return (known, nil)
    }
}
