import BaguetteDevice
import Foundation

/// AppleScript click of Simulator → I/O → External Displays → CarPlay.
/// Raises the phone window first so the menu targets the right device.
/// For a wedged solid-black external, call `recoverCarPlay()` (Disabled
/// → CarPlay) instead of this enable path.
final class SimulatorMenuExternalDisplayPanel: ExternalDisplayPanel, @unchecked Sendable {
    private let osascript: URL

    init(osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.osascript = osascript
    }

    func enableCarPlay() throws {
        try run("""
            tell application "Simulator" to activate
            delay 0.4
            tell application "System Events"
              tell process "Simulator"
                set frontmost to true
                repeat with w in every window
                  set n to name of w
                  if n contains "iPhone" and n does not contain "CarPlay" then
                    perform action "AXRaise" of w
                    exit repeat
                  end if
                end repeat
                delay 0.25
                set ioMenu to menu "I/O" of menu bar 1
                set extItem to menu item "External Displays" of ioMenu
                click extItem
                delay 0.25
                click menu item "CarPlay" of menu 1 of extItem
                delay 1.0
              end tell
            end tell
            """)
    }

    /// Spike recovery for a persistent black TVOut surface.
    func recoverCarPlay() throws {
        try run("""
            tell application "Simulator" to activate
            delay 0.4
            tell application "System Events"
              tell process "Simulator"
                set frontmost to true
                repeat with w in every window
                  set n to name of w
                  if n contains "iPhone" and n does not contain "CarPlay" then
                    perform action "AXRaise" of w
                    exit repeat
                  end if
                end repeat
                delay 0.25
                set ioMenu to menu "I/O" of menu bar 1
                set extItem to menu item "External Displays" of ioMenu
                click extItem
                delay 0.25
                click menu item "Disabled" of menu 1 of extItem
                delay 1.2
                click extItem
                delay 0.25
                click menu item "CarPlay" of menu 1 of extItem
                delay 1.5
              end tell
            end tell
            """)
    }

    private func run(_ script: String) throws {
        let process = Process()
        process.executableURL = osascript
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExternalDisplaysError.enableFailed(status: process.terminationStatus)
        }
    }
}

enum ExternalDisplaysError: Error, Equatable {
    case enableFailed(status: Int32)
}
