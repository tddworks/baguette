import Foundation

/// Handles MCP (Model Context Protocol) JSON-RPC requests for a single
/// simulator session. Each `handle(line:)` call parses one JSON-RPC
/// request and returns the response string, or `nil` for notifications.
///
/// Tools mirror baguette's existing capabilities — `describe_ui`, `tap`,
/// `type_text`, `press_key`, `swipe`, `press_button`, `screenshot` — so
/// an MCP client gets the same surface as the CLI and WebSocket, with
/// structured tool definitions and JSON-RPC framing.
final class McpHandler: @unchecked Sendable {
    private let simulator: any Simulator

    init(simulator: any Simulator) {
        self.simulator = simulator
    }

    func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return nil
        }

        let id = json["id"]

        if method.hasPrefix("notifications/") {
            return nil
        }

        guard let id else {
            return nil
        }

        switch method {
        case "initialize":
            return initializeResponse(id: id)
        case "tools/list":
            return toolsListResponse(id: id)
        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            return await toolCallResponse(id: id, params: params)
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Initialize

    private func initializeResponse(id: Any) -> String {
        return jsonRpcResult(id: id, result: """
        {"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"baguette","version":"\(baguetteVersion)"}}
        """)
    }

    // MARK: - Tools List

    private func toolsListResponse(id: Any) -> String {
        return jsonRpcResult(id: id, result: #"{"tools":[\#(Self.toolDefinitions)]}"#)
    }

    // MARK: - Tool Call

    private func toolCallResponse(id: Any, params: [String: Any]) async -> String {
        guard let name = params["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        do {
            let content = try await dispatchTool(name: name, arguments: args)
            return jsonRpcResult(id: id, result: #"{"content":[\#(content)]}"#)
        } catch {
            return jsonRpcResult(id: id, result: #"{"content":[{"type":"text","text":"\#(Self.jsonEscape(String(describing: error)))"}],"isError":true}"#)
        }
    }

    private func dispatchTool(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "describe_ui":
            return try await toolDescribeUI(arguments)
        case "tap":
            return try toolTap(arguments)
        case "type_text":
            return try toolTypeText(arguments)
        case "press_key":
            return try toolPressKey(arguments)
        case "swipe":
            return try toolSwipe(arguments)
        case "press_button":
            return try toolPressButton(arguments)
        case "screenshot":
            return try await toolScreenshot(arguments)
        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Tool Implementations

    private func toolDescribeUI(_ args: [String: Any]) async throws -> String {
        let ax = simulator.accessibility()
        let result: AXNode?
        if let x = args["x"] as? Double, let y = args["y"] as? Double {
            result = try ax.describeAt(point: Point(x: x, y: y))
        } else {
            result = try ax.describeAll()
        }
        guard let tree = result else {
            return #"{"type":"text","text":"no accessibility data"}"#
        }
        return #"{"type":"text","text":\#(Self.jsonQuote(tree.json))}"#
    }

    private func toolTap(_ args: [String: Any]) throws -> String {
        let x = try requireDouble(args, "x")
        let y = try requireDouble(args, "y")
        let width = try requireDouble(args, "width")
        let height = try requireDouble(args, "height")
        let duration = (args["duration"] as? Double) ?? 0.05
        let tap = Tap(at: Point(x: x, y: y), size: Size(width: width, height: height), duration: duration)
        let ok = tap.execute(on: simulator.input())
        return #"{"type":"text","text":"tap \#(ok ? "ok" : "failed") at (\#(Int(x)),\#(Int(y)))"}"#
    }

    private func toolTypeText(_ args: [String: Any]) throws -> String {
        let text = try requireString(args, "text")
        let gesture = try TypeText.parse(["type": "type", "text": text])
        let ok = gesture.execute(on: simulator.input())
        return #"{"type":"text","text":"type \#(ok ? "ok" : "failed"): \#(Self.jsonEscape(text))"}"#
    }

    private func toolPressKey(_ args: [String: Any]) throws -> String {
        let code = try requireString(args, "code")
        var dict: [String: Any] = ["type": "key", "code": code]
        if let mods = args["modifiers"] as? [String] {
            dict["modifiers"] = mods
        }
        let gesture = try Key.parse(dict)
        let ok = gesture.execute(on: simulator.input())
        return #"{"type":"text","text":"key \#(ok ? "ok" : "failed"): \#(code)"}"#
    }

    private func toolSwipe(_ args: [String: Any]) throws -> String {
        let startX = try requireDouble(args, "startX")
        let startY = try requireDouble(args, "startY")
        let endX = try requireDouble(args, "endX")
        let endY = try requireDouble(args, "endY")
        let width = try requireDouble(args, "width")
        let height = try requireDouble(args, "height")
        let duration = (args["duration"] as? Double) ?? 0.3
        let swipe = Swipe(
            from: Point(x: startX, y: startY),
            to: Point(x: endX, y: endY),
            size: Size(width: width, height: height),
            duration: duration
        )
        let ok = swipe.execute(on: simulator.input())
        return #"{"type":"text","text":"swipe \#(ok ? "ok" : "failed")"}"#
    }

    private func toolPressButton(_ args: [String: Any]) throws -> String {
        let name = try requireString(args, "button")
        guard let button = Self.buttonMap[name] else {
            throw ToolError.invalidValue("button", name, "home | lock | power | volume-up | volume-down | action")
        }
        let duration = (args["duration"] as? Double) ?? 0.1
        let ok = simulator.input().button(button, duration: duration)
        return #"{"type":"text","text":"button \#(ok ? "ok" : "failed"): \#(name)"}"#
    }

    private func toolScreenshot(_ args: [String: Any]) async throws -> String {
        let quality = (args["quality"] as? Double) ?? 0.85
        let scale = (args["scale"] as? Int) ?? 2
        let bytes = try await ScreenSnapshot.capture(
            screen: simulator.screen(),
            quality: quality,
            scale: max(1, scale)
        )
        let base64 = bytes.base64EncodedString()
        return #"{"type":"image","data":"\#(base64)","mimeType":"image/jpeg"}"#
    }

    // MARK: - Helpers

    private func requireDouble(_ dict: [String: Any], _ key: String) throws -> Double {
        if let v = dict[key] as? Double { return v }
        if let v = dict[key] as? Int { return Double(v) }
        throw ToolError.missingField(key)
    }

    private func requireString(_ dict: [String: Any], _ key: String) throws -> String {
        guard let v = dict[key] as? String else {
            throw ToolError.missingField(key)
        }
        return v
    }

    private static let buttonMap: [String: DeviceButton] = [
        "home": .home, "lock": .lock, "power": .power,
        "volume-up": .volumeUp, "volume-down": .volumeDown,
        "action": .action,
    ]

    // MARK: - JSON-RPC Framing

    private func jsonRpcResult(id: Any, result: String) -> String {
        let idStr = Self.jsonId(id)
        return #"{"jsonrpc":"2.0","id":\#(idStr),"result":\#(result)}"#
    }

    private func errorResponse(id: Any, code: Int, message: String) -> String {
        let idStr = Self.jsonId(id)
        return #"{"jsonrpc":"2.0","id":\#(idStr),"error":{"code":\#(code),"message":"\#(Self.jsonEscape(message))"}}"#
    }

    private static func jsonId(_ id: Any) -> String {
        if let n = id as? Int { return "\(n)" }
        if let s = id as? String { return "\"\(jsonEscape(s))\"" }
        return "null"
    }

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"":  out.append("\\\"")
            case "\\":  out.append("\\\\")
            case "\n":  out.append("\\n")
            case "\r":  out.append("\\r")
            case "\t":  out.append("\\t")
            default:
                if ch.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.value))
                } else {
                    out.append(Character(ch))
                }
            }
        }
        return out
    }

    private static func jsonQuote(_ s: String) -> String {
        return "\"\(jsonEscape(s))\""
    }

    // MARK: - Tool Definitions

    static let toolDefinitions: String = """
    {"name":"describe_ui","description":"Get the simulator's on-screen accessibility tree as JSON. Each node has role, label, value, identifier, frame {x,y,width,height} in device points. Optionally hit-test a single point.","inputSchema":{"type":"object","properties":{"x":{"type":"number","description":"Hit-test x coordinate (device points). Pair with y."},"y":{"type":"number","description":"Hit-test y coordinate (device points). Pair with x."}}}},\
    {"name":"tap","description":"Tap at a point on the simulator screen.","inputSchema":{"type":"object","properties":{"x":{"type":"number","description":"X coordinate in device points"},"y":{"type":"number","description":"Y coordinate in device points"},"width":{"type":"number","description":"Screen width in device points"},"height":{"type":"number","description":"Screen height in device points"},"duration":{"type":"number","description":"Hold duration in seconds (default 0.05)"}},"required":["x","y","width","height"]}},\
    {"name":"type_text","description":"Type a text string on the simulator. US ASCII printable only.","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"Text to type"}},"required":["text"]}},\
    {"name":"press_key","description":"Press a keyboard key. Uses W3C KeyboardEvent.code names.","inputSchema":{"type":"object","properties":{"code":{"type":"string","description":"Key code (Enter, Backspace, Tab, Space, KeyA-KeyZ, Digit0-Digit9, Arrow*, etc.)"},"modifiers":{"type":"array","items":{"type":"string","enum":["shift","control","option","command"]},"description":"Modifier keys to hold"}},"required":["code"]}},\
    {"name":"swipe","description":"Swipe from one point to another.","inputSchema":{"type":"object","properties":{"startX":{"type":"number"},"startY":{"type":"number"},"endX":{"type":"number"},"endY":{"type":"number"},"width":{"type":"number","description":"Screen width in device points"},"height":{"type":"number","description":"Screen height in device points"},"duration":{"type":"number","description":"Swipe duration in seconds (default 0.3)"}},"required":["startX","startY","endX","endY","width","height"]}},\
    {"name":"press_button","description":"Press a hardware button on the simulator.","inputSchema":{"type":"object","properties":{"button":{"type":"string","enum":["home","lock","power","volume-up","volume-down","action"],"description":"Button name"},"duration":{"type":"number","description":"Hold duration in seconds (default 0.1)"}},"required":["button"]}},\
    {"name":"screenshot","description":"Capture a JPEG screenshot of the simulator screen.","inputSchema":{"type":"object","properties":{"quality":{"type":"number","description":"JPEG quality 0.0-1.0 (default 0.85)"},"scale":{"type":"integer","description":"Integer downscale divisor (default 2)"}}}}
    """
}

// MARK: - Errors

enum ToolError: Error, CustomStringConvertible {
    case unknownTool(String)
    case missingField(String)
    case invalidValue(String, String, String)

    var description: String {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .missingField(let field): return "Missing required field: \(field)"
        case .invalidValue(let field, let value, let expected): return "Invalid \(field): '\(value)' (expected: \(expected))"
        }
    }
}
