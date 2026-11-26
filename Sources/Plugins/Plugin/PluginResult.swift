import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation

/// What a plugin command says when it's done — one JSON object on
/// stdout, parsed here.
///
/// Two failures are deliberately different things. `ok: false` is the
/// plugin reporting honestly that its job didn't work ("Metro isn't
/// running"); baguette shows the plugin's own `message`. A throw from
/// `parsing` is the plugin failing to hold up its end of the contract,
/// and baguette says so in its own words. Conflating them would let a
/// crashed plugin read as a clean result.
struct PluginResult: Equatable, Sendable {
    let ok: Bool
    /// Plugin-authored line for the toast. `nil` when it had nothing
    /// to add beyond the rows.
    let message: String?
    let rows: [ResultRow]

    init(ok: Bool, message: String? = nil, rows: [ResultRow] = []) {
        self.ok = ok
        self.message = message
        self.rows = rows
    }

    // MARK: - parsing

    static func parsing(json data: Data) throws -> PluginResult {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PluginResultError.malformedJSON
        }
        guard let dict = raw as? [String: Any] else {
            throw PluginResultError.malformedJSON
        }

        let rowDicts = dict["rows"] as? [[String: Any]] ?? []
        let rows = try rowDicts.enumerated().map { index, rowDict in
            try ResultRow.parsing(dict: rowDict, index: index)
        }

        return PluginResult(
            ok: dict["ok"] as? Bool ?? false,
            message: dict["message"] as? String,
            rows: rows
        )
    }
}

/// One line in a `list` panel.
struct ResultRow: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let severity: RowSeverity
    /// Device points — the same space as gesture wire coordinates, so
    /// `RowAction.highlight` / `.tap` need no conversion.
    let frame: Rect?
    /// Payload for `RowAction.copy`.
    let copy: String?
    /// Payload for `RowAction.fill` — what this row types into the
    /// panel's prompt.
    ///
    /// Separate from `title` on purpose: a title is display text, so it
    /// may be truncated, decorated or translated, and reusing it would
    /// make every one of those a silent change to what gets typed.
    let fill: String?
    /// Command id to invoke for `RowAction.run` — one of the ids this
    /// plugin contributes. Absent on the rows that just report.
    let run: String?
    /// Arguments handed to that command, in the context JSON it reads
    /// on stdin. Only meaningful alongside `run`.
    let args: PluginArgs?
    /// Whether this row's control is on, when the panel declares one.
    /// `nil` means the row isn't a control at all — which is how a
    /// section header or a plain note keeps rendering as itself inside a
    /// panel full of switches.
    let state: RowState?
    /// What a ticked row submits under the control's `arg`. Required
    /// alongside `state`: a tick that carried nothing would be a control
    /// the plugin can't act on.
    let value: String?
    /// Which set of options a `radio` row is exclusive within.
    ///
    /// This is what lets one panel ask more than one question. A
    /// settings panel is normally several independent choices at once —
    /// appearance, contrast and text size — and without groups, picking
    /// "Dark" would unpick the text size. Rows naming none share one
    /// implicit group, which is the single-question panel. Meaningless
    /// for `switch` / `checkbox`, which have no exclusivity to express.
    let group: String?

    init(
        title: String,
        subtitle: String? = nil,
        severity: RowSeverity = .info,
        frame: Rect? = nil,
        copy: String? = nil,
        fill: String? = nil,
        run: String? = nil,
        args: [String: Any]? = nil,
        state: RowState? = nil,
        value: String? = nil,
        group: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.severity = severity
        self.frame = frame
        self.copy = copy
        self.fill = fill
        self.run = run
        self.args = args.flatMap(PluginArgs.init)
        self.state = state
        self.value = value
        self.group = group
    }

    static func parsing(dict: [String: Any], index: Int) throws -> ResultRow {
        guard let title = dict["title"] as? String, !title.isEmpty else {
            throw PluginResultError.rowMissingTitle(index: index)
        }

        var severity = RowSeverity.info
        if let raw = dict["severity"] as? String {
            guard let parsed = RowSeverity(rawValue: raw) else {
                throw PluginResultError.unknownSeverity(name: raw, index: index)
            }
            severity = parsed
        }

        // `run` / `args` travel together: arguments addressed to no
        // command are a bug worth naming, because silently dropping them
        // leaves a row that looks clickable and does nothing.
        var run: String?
        if let rawRun = dict["run"] {
            guard let id = rawRun as? String, !id.isEmpty else {
                throw PluginResultError.malformedRun(index: index)
            }
            run = id
        }

        var args: [String: Any]?
        if let rawArgs = dict["args"] {
            guard run != nil else { throw PluginResultError.argsWithoutRun(index: index) }
            guard let object = rawArgs as? [String: Any],
                  PluginArgs(object) != nil else {
                throw PluginResultError.malformedArgs(index: index)
            }
            args = object
        }

        // `state` / `value` travel together for the same reason `run` and
        // `args` do: a tick with nothing to submit is a control the
        // plugin can't act on, and rendering it anyway makes a switch
        // that flips and changes nothing.
        var state: RowState?
        if let rawState = dict["state"] {
            guard let name = rawState as? String, let parsed = RowState(rawValue: name) else {
                throw PluginResultError.unknownRowState(
                    name: (rawState as? String) ?? String(describing: rawState), index: index
                )
            }
            guard let value = dict["value"] as? String, !value.isEmpty else {
                throw PluginResultError.stateWithoutValue(index: index)
            }
            state = parsed
        }

        return ResultRow(
            title: title,
            subtitle: dict["subtitle"] as? String,
            severity: severity,
            frame: try frameValue(dict["frame"], index: index),
            copy: dict["copy"] as? String,
            fill: dict["fill"] as? String,
            run: run,
            args: args,
            state: state,
            // Only meaningful alongside `state`; a bare `value` on a
            // plain row is ignored rather than made up into a control.
            value: state == nil ? nil : dict["value"] as? String,
            group: state == nil ? nil : dict["group"] as? String
        )
    }

    /// Frames arrive flat (`x` / `y` / `width` / `height`) because
    /// that's the shape every other baguette wire surface uses. All
    /// four are required — half a frame can't be highlighted or
    /// tapped, and guessing the rest would paint a box somewhere the
    /// plugin never meant.
    private static func frameValue(_ value: Any?, index: Int) throws -> Rect? {
        guard let value else { return nil }
        guard let dict = value as? [String: Any] else {
            throw PluginResultError.malformedFrame(index: index)
        }
        guard let x = dict["x"] as? Double ?? (dict["x"] as? Int).map(Double.init),
              let y = dict["y"] as? Double ?? (dict["y"] as? Int).map(Double.init),
              let w = dict["width"] as? Double ?? (dict["width"] as? Int).map(Double.init),
              let h = dict["height"] as? Double ?? (dict["height"] as? Int).map(Double.init)
        else {
            throw PluginResultError.malformedFrame(index: index)
        }
        return Rect(origin: Point(x: x, y: y), size: Size(width: w, height: h))
    }
}

/// How a row is styled. Closed set — the host owns the colours.
enum RowSeverity: String, Equatable, Sendable, CaseIterable {
    case info, warn, error
}

/// Whether a tickable row is on, as the **device** last reported it.
///
/// Not what the user has clicked since: the page tracks pending ticks
/// separately, so a row whose local tick disagrees with this can be
/// drawn as unconfirmed rather than settled. This value is always the
/// plugin's last word, which is what makes "what you see is what the
/// device reports" survive batching.
enum RowState: String, Equatable, Sendable, CaseIterable {
    case on, off
}

/// Why a plugin's answer couldn't be rendered. Every case names the
/// offending row so the author can find it.
enum PluginResultError: Error, Equatable, CustomStringConvertible {
    case malformedJSON
    case rowMissingTitle(index: Int)
    case unknownSeverity(name: String, index: Int)
    case malformedFrame(index: Int)
    case malformedRun(index: Int)
    case malformedArgs(index: Int)
    case argsWithoutRun(index: Int)
    case unknownRowState(name: String, index: Int)
    case stateWithoutValue(index: Int)

    var description: String {
        switch self {
        case .malformedJSON:
            return "plugin did not print a JSON object on stdout"
        case .unknownRowState(let name, let index):
            return """
                row \(index) has state \"\(name)\" — use one of: \
                \(RowState.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .stateWithoutValue(let index):
            return """
                row \(index) has \"state\" but no non-empty \"value\" — \
                ticking it would submit nothing
                """
        case .malformedRun(let index):
            return "row \(index) has a \"run\" that isn't a non-empty command id"
        case .malformedArgs(let index):
            return "row \(index) has \"args\" that isn't a JSON object"
        case .argsWithoutRun(let index):
            return "row \(index) has \"args\" but no \"run\" naming the command to pass them to"
        case .rowMissingTitle(let index):
            return "row \(index) has no non-empty \"title\""
        case .unknownSeverity(let name, let index):
            return """
                row \(index) has unknown severity \"\(name)\" — use one of: \
                \(RowSeverity.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .malformedFrame(let index):
            return "row \(index) has a frame missing one of x / y / width / height"
        }
    }
}
