import Foundation

/// Reads web content from Safari / WKWebView via the WebKit Remote
/// Debugging Protocol. Connects to `webinspectord_sim`'s Unix socket,
/// performs the WIR binary-plist handshake, and evaluates JavaScript
/// to extract visible DOM elements with their bounding rectangles.
///
/// Returns an array of `AXNode` values that the caller can graft
/// onto the native accessibility tree so `describe-ui` shows web
/// content alongside Safari's chrome.
///
/// Coordinates are in **device points** (CSS pixels on iOS map 1:1
/// to device points for standard-viewport pages), offset by the
/// web content area's position within the full screen.
enum WebContentReader {

    /// Extract visible DOM elements from the frontmost Safari page
    /// on the given simulator. Returns `nil` when no inspectable
    /// page is found or the JS evaluation fails.
    static func readWebContent(
        simulatorUDID udid: String,
        screenHeight: Double = 874
    ) -> [AXNode]? {
        let socketPaths = findAllSockets()
        if socketPaths.isEmpty {
            logErr("[web] no webinspectord sockets found")
            return nil
        }
        for socketPath in socketPaths {
            if let result = trySocket(path: socketPath, screenHeight: screenHeight) {
                return result
            }
        }
        logErr("[web] no inspectable Safari page on any socket")
        return nil
    }

    private static func trySocket(path: String, screenHeight: Double) -> [AXNode]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard connectUnix(fd: fd, path: path) else { return nil }

        let connId = UUID().uuidString
        let senderId = UUID().uuidString

        // Step 1: reportIdentifier
        sendPlist(fd: fd, [
            "__selector": "_rpc_reportIdentifier:",
            "__argument": ["WIRConnectionIdentifierKey": connId],
        ])

        // Step 2: read until we find Safari app + page
        var appId: String?
        var pageId: Any?
        let setupDeadline = Date().addingTimeInterval(5)

        while Date() < setupDeadline {
            guard let msg = recvPlist(fd: fd, timeout: 3) else { break }
            let sel = msg["__selector"] as? String ?? ""
            let arg = msg["__argument"] as? [String: Any] ?? [:]

            if sel == "_rpc_reportConnectedApplicationList:" {
                let apps = arg["WIRApplicationDictionaryKey"] as? [String: Any] ?? [:]
                for (aid, info) in apps {
                    let bundle = (info as? [String: Any])?["WIRApplicationBundleIdentifierKey"] as? String ?? ""
                    if bundle.lowercased().contains("mobilesafari") || bundle.lowercased().contains("webkit") {
                        appId = aid
                    }
                }
            } else if sel == "_rpc_applicationSentListing:" {
                let listing = arg["WIRListingKey"] as? [String: Any] ?? [:]
                for (pid, info) in listing {
                    let url = (info as? [String: Any])?["WIRURLKey"] as? String ?? ""
                    if !url.isEmpty, !url.hasPrefix("about:") {
                        pageId = Int(pid) ?? pid
                    }
                }
            } else if sel == "_rpc_applicationUpdated:" {
                if appId == nil { appId = arg["WIRApplicationIdentifierKey"] as? String }
                if appId != nil, pageId == nil {
                    sendPlist(fd: fd, [
                        "__selector": "_rpc_forwardGetListing:",
                        "__argument": [
                            "WIRConnectionIdentifierKey": connId,
                            "WIRApplicationIdentifierKey": appId!,
                        ],
                    ])
                }
            }
            if appId != nil, pageId != nil { break }
        }

        guard let appId, let pageId else {
            logErr("[web] no inspectable Safari page found")
            return nil
        }

        // Step 3: forwardSocketSetup
        sendPlist(fd: fd, [
            "__selector": "_rpc_forwardSocketSetup:",
            "__argument": [
                "WIRApplicationIdentifierKey": appId,
                "WIRConnectionIdentifierKey": connId,
                "WIRSenderKey": senderId,
                "WIRPageIdentifierKey": pageId,
                "WIRAutomaticallyPause": false,
            ] as [String: Any],
        ])

        // Step 4: read setup responses, find page target
        var targetId: String?
        let targetDeadline = Date().addingTimeInterval(3)
        while Date() < targetDeadline {
            guard let msg = recvPlist(fd: fd, timeout: 2) else { break }
            let sel = msg["__selector"] as? String ?? ""
            if sel == "_rpc_applicationSentData:" {
                let arg = msg["__argument"] as? [String: Any] ?? [:]
                if let data = arg["WIRMessageDataKey"] as? Data,
                   let text = String(data: data, encoding: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   (json["method"] as? String) == "Target.targetCreated" {
                    let tid = ((json["params"] as? [String: Any])?["targetInfo"] as? [String: Any])?["targetId"] as? String ?? ""
                    if tid.hasPrefix("page-") { targetId = tid }
                }
            }
        }

        guard let targetId else {
            logErr("[web] no page target created")
            return nil
        }

        // Step 5: evaluate JavaScript
        let js = Self.domExtractionJS
        let innerCmd: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": js,
                "returnByValue": true,
                "objectGroup": "baguette",
                "includeCommandLineAPI": true,
                "doNotPauseOnExceptionsAndMuteConsole": false,
                "emulateUserGesture": false,
                "generatePreview": false,
                "saveResult": false,
            ] as [String: Any],
        ]
        guard let innerJSON = try? JSONSerialization.data(withJSONObject: innerCmd),
              let innerStr = String(data: innerJSON, encoding: .utf8) else { return nil }

        let wrapper: [String: Any] = [
            "id": 1,
            "method": "Target.sendMessageToTarget",
            "params": ["targetId": targetId, "message": innerStr],
        ]
        guard let wrapperJSON = try? JSONSerialization.data(withJSONObject: wrapper),
              let wrapperStr = String(data: wrapperJSON, encoding: .utf8) else { return nil }

        sendPlist(fd: fd, [
            "__selector": "_rpc_forwardSocketData:",
            "__argument": [
                "WIRSocketDataKey": Data(wrapperStr.utf8),
                "WIRConnectionIdentifierKey": connId,
                "WIRSenderKey": senderId,
                "WIRApplicationIdentifierKey": appId,
                "WIRPageIdentifierKey": pageId,
            ] as [String: Any],
        ])

        // Step 6: read result
        let evalDeadline = Date().addingTimeInterval(5)
        while Date() < evalDeadline {
            guard let msg = recvPlist(fd: fd, timeout: 5) else { break }
            let sel = msg["__selector"] as? String ?? ""
            if sel == "_rpc_applicationSentData:" {
                let arg = msg["__argument"] as? [String: Any] ?? [:]
                guard let data = arg["WIRMessageDataKey"] as? Data,
                      let text = String(data: data, encoding: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      (json["method"] as? String) == "Target.dispatchMessageFromTarget",
                      let innerMsg = (json["params"] as? [String: Any])?["message"] as? String,
                      let inner = try? JSONSerialization.jsonObject(with: Data(innerMsg.utf8)) as? [String: Any],
                      let result = (inner["result"] as? [String: Any])?["result"] as? [String: Any],
                      let value = result["value"] else { continue }

                let elements: [[String: Any]]
                if let arr = value as? [[String: Any]] {
                    elements = arr
                } else if let str = value as? String,
                          let parsed = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [[String: Any]] {
                    elements = parsed
                } else { continue }

                return elements.compactMap { Self.elementToAXNode($0, screenHeight: screenHeight) }
            }
        }

        logErr("[web] JS evaluation timed out")
        return nil
    }

    // MARK: - DOM → AXNode

    private static func elementToAXNode(_ el: [String: Any], screenHeight: Double) -> AXNode? {
        let x = (el["x"] as? Double) ?? Double(el["x"] as? Int ?? 0)
        let y = (el["y"] as? Double) ?? Double(el["y"] as? Int ?? 0)
        let w = (el["w"] as? Double) ?? Double(el["w"] as? Int ?? 0)
        let h = (el["h"] as? Double) ?? Double(el["h"] as? Int ?? 0)
        guard w > 0, h > 0 else { return nil }

        let tag = (el["tag"] as? String ?? "").uppercased()
        let text = el["text"] as? String
        let href = el["href"] as? String
        let inputType = el["type"] as? String
        let placeholder = el["placeholder"] as? String
        let ariaLabel = el["ariaLabel"] as? String

        let role = Self.tagToRole(tag, inputType: inputType)
        let label = ariaLabel?.isEmpty == false ? ariaLabel
                  : text?.isEmpty == false ? text
                  : placeholder?.isEmpty == false ? placeholder
                  : nil
        let value = tag == "INPUT" ? (el["value"] as? String) : href

        return AXNode(
            role: role,
            label: label,
            value: value,
            identifier: el["id"] as? String,
            frame: Rect(
                origin: Point(x: x, y: y),
                size: Size(width: w, height: h)
            ),
            enabled: true
        )
    }

    private static func tagToRole(_ tag: String, inputType: String?) -> String {
        switch tag {
        case "A":      return "AXLink"
        case "BUTTON": return "AXButton"
        case "INPUT":
            switch inputType?.lowercased() {
            case "submit", "button": return "AXButton"
            case "checkbox":         return "AXCheckBox"
            case "radio":            return "AXRadioButton"
            default:                 return "AXTextField"
            }
        case "TEXTAREA": return "AXTextArea"
        case "SELECT":   return "AXPopUpButton"
        case "IMG":      return "AXImage"
        case "H1", "H2", "H3", "H4", "H5", "H6": return "AXHeading"
        case "LABEL":    return "AXStaticText"
        case "P":        return "AXStaticText"
        case "SPAN":     return "AXStaticText"
        case "NAV":      return "AXGroup"
        case "SECTION":  return "AXGroup"
        case "DIV":      return "AXGroup"
        case "FORM":     return "AXGroup"
        default:         return "AXGroup"
        }
    }

    // MARK: - JavaScript

    private static let domExtractionJS = """
    (function() {
        var tags = "a,button,input,textarea,select,h1,h2,h3,h4,label,img,nav,p,span";
        var els = document.querySelectorAll(tags);
        var vh = window.innerHeight;
        var result = [];
        for (var i = 0; i < els.length && result.length < 100; i++) {
            var el = els[i];
            var r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0 || r.bottom < 0 || r.top > vh) continue;
            var text = (el.innerText || "").trim().substring(0, 100);
            if (!text && el.tagName === "IMG") text = el.getAttribute("alt") || "";
            result.push({
                tag: el.tagName,
                text: text,
                ariaLabel: el.getAttribute("aria-label") || "",
                href: el.getAttribute("href") || "",
                type: el.getAttribute("type") || "",
                placeholder: el.getAttribute("placeholder") || "",
                id: el.id || "",
                value: el.value || "",
                x: Math.round(r.x),
                y: Math.round(r.y),
                w: Math.round(r.width),
                h: Math.round(r.height)
            });
        }
        return result;
    })()
    """

    // MARK: - Socket helpers

    private static func findAllSockets() -> [String] {
        let dirs = ["/private/var/tmp", "/private/tmp"]
        let fm = FileManager.default
        var result: [String] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasPrefix("com.apple.launchd.") {
                let path = "\(dir)/\(entry)/com.apple.webinspectord_sim.socket"
                if fm.fileExists(atPath: path) {
                    result.append(path)
                }
            }
        }
        return result
    }

    private static func connectUnix(fd: Int32, path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBufferPointer { src in
                UnsafeMutableRawPointer(ptr).copyMemory(
                    from: src.baseAddress!, byteCount: min(src.count, 104)
                )
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private static func sendPlist(fd: Int32, _ dict: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0
        ) else { return }
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { send(fd, $0.baseAddress!, 4, 0) }
        data.withUnsafeBytes { send(fd, $0.baseAddress!, data.count, 0) }
    }

    private static func recvPlist(fd: Int32, timeout: Double) -> [String: Any]? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard recv(fd, &lenBuf, 4, MSG_WAITALL) == 4 else { return nil }
        let len = Int(Data(lenBuf).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard len > 0, len < 10_000_000 else { return nil }

        var buf = [UInt8](repeating: 0, count: len)
        var received = 0
        while received < len {
            let n = recv(fd, &buf[received], len - received, 0)
            if n <= 0 { return nil }
            received += n
        }
        return try? PropertyListSerialization.propertyList(
            from: Data(buf), format: nil
        ) as? [String: Any]
    }
}
