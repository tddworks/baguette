import BaguetteDevice
import Foundation
import Mockable

/// This login session's display configuration: which display is main, where
/// each one is, and every display placed at once (for this session only,
/// never saved). Decides nothing; the real one is `CoreGraphicsDisplayConfiguration`.
@Mockable
protocol DisplayConfiguration: Sendable {
    var main: UInt32 { get }
    /// Where each listed display is; nil when the list can't be read.
    func bounds() -> [UInt32: Rect]?
    func place(_ origins: [UInt32: Point])
}

/// Making one display main — run in a `baguette main-display` process of its
/// own: a process that changes the arrangement stops seeing displays added
/// after it. Where each display goes is `DisplayOrigins`'. Measured: a
/// display made a moment ago is listed half a second later, so this waits for
/// it to be listed, and checks it took — for two seconds at most.
struct MainDisplayMove {
    let configuration: any DisplayConfiguration
    let pause: @Sendable (TimeInterval) -> Void

    static let tries = 40
    static let interval: TimeInterval = 0.05

    init(configuration: any DisplayConfiguration,
         pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.configuration = configuration
        self.pause = pause
    }

    /// `freeing`: the Dock's side, when the display should have nothing
    /// beside that edge (a share made main); nil only shifts the arrangement.
    func makeMain(_ display: UInt32, freeing edge: DockEdge? = nil) -> Bool {
        for attempt in 0..<Self.tries {
            if configuration.main == display {
                if attempt > 0 { log("[mac] display \(display) is main after \(attempt) tries") }
                return true
            }
            if let now = configuration.bounds(), now[display] != nil,
               let moved = DisplayOrigins.makingMain(display, in: now, freeing: edge) {
                configuration.place(moved)
            } else if attempt % 10 == 0 {
                log("[mac] display \(display) not listed yet (main \(configuration.main))")
            }
            pause(Self.interval)
        }
        log("[mac] display \(display) never became main (main \(configuration.main))")
        return configuration.main == display
    }
}
