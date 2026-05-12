import Testing
import Mockable
@testable import Baguette

@Suite("McpHandler")
struct McpHandlerTests {

    // MARK: - Protocol

    @Test func `responds to initialize with server info and tools capability`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)

        #expect(response != nil)
        #expect(response!.contains("\"protocolVersion\""))
        #expect(response!.contains("\"tools\""))
        #expect(response!.contains("\"baguette\""))
        #expect(response!.contains("\"id\":1"))
    }

    @Test func `returns nil for notifications`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        #expect(response == nil)
    }

    @Test func `returns error for unknown method`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"unknown/thing","params":{}}"#)

        #expect(response != nil)
        #expect(response!.contains("\"error\""))
        #expect(response!.contains("Method not found"))
    }

    @Test func `lists all seven tools`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)

        #expect(response != nil)
        #expect(response!.contains("describe_ui"))
        #expect(response!.contains("tap"))
        #expect(response!.contains("type_text"))
        #expect(response!.contains("press_key"))
        #expect(response!.contains("swipe"))
        #expect(response!.contains("press_button"))
        #expect(response!.contains("screenshot"))
    }

    // MARK: - Tool: tap

    @Test func `tap tool dispatches to input and returns ok`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        given(input).tap(at: .any, size: .any, duration: .any).willReturn(true)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tap","arguments":{"x":100,"y":200,"width":400,"height":800}}}"#)

        #expect(response != nil)
        #expect(response!.contains("tap ok"))
    }

    @Test func `tap tool returns error on missing field`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tap","arguments":{"x":100}}}"#)

        #expect(response != nil)
        #expect(response!.contains("isError"))
        #expect(response!.contains("Missing required field: y"))
    }

    // MARK: - Tool: type_text

    @Test func `type_text tool dispatches to input`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"type_text","arguments":{"text":"hi"}}}"#)

        #expect(response != nil)
        #expect(response!.contains("type ok"))
    }

    // MARK: - Tool: press_key

    @Test func `press_key tool dispatches Enter`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        given(input).key(.any, modifiers: .any, duration: .any).willReturn(true)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"press_key","arguments":{"code":"Enter"}}}"#)

        #expect(response != nil)
        #expect(response!.contains("key ok"))
    }

    // MARK: - Tool: swipe

    @Test func `swipe tool dispatches to input`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        given(input).swipe(from: .any, to: .any, size: .any, duration: .any).willReturn(true)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"swipe","arguments":{"startX":100,"startY":400,"endX":100,"endY":100,"width":400,"height":800}}}"#)

        #expect(response != nil)
        #expect(response!.contains("swipe ok"))
    }

    // MARK: - Tool: press_button

    @Test func `press_button tool dispatches home button`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        given(input).button(.any, duration: .any).willReturn(true)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"press_button","arguments":{"button":"home"}}}"#)

        #expect(response != nil)
        #expect(response!.contains("button ok"))
    }

    @Test func `press_button tool rejects invalid button name`() async {
        let sim = MockSimulator()
        let input = MockInput()
        given(sim).input().willReturn(input)
        let handler = McpHandler(simulator: sim)

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"press_button","arguments":{"button":"siri"}}}"#)

        #expect(response != nil)
        #expect(response!.contains("isError"))
    }

    // MARK: - Tool: unknown

    @Test func `unknown tool returns error`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"frobnicate","arguments":{}}}"#)

        #expect(response != nil)
        #expect(response!.contains("isError"))
        #expect(response!.contains("Unknown tool"))
    }

    // MARK: - Malformed input

    @Test func `returns nil for invalid JSON`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: "not json")

        #expect(response == nil)
    }

    @Test func `returns nil for missing method`() async {
        let handler = McpHandler(simulator: MockSimulator())

        let response = await handler.handle(line: #"{"jsonrpc":"2.0","id":1}"#)

        #expect(response == nil)
    }
}
