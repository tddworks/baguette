import BaguetteDevice
import Foundation

extension StreamDisplayPlan {
    /// Enables CarPlay when asked, then returns screen + input for the
    /// planned plane. Phone keeps the legacy `Simulator.screen` /
    /// `input` aliases; CarPlay takes both from the `displays`
    /// aggregate so framebuffer and HID share one binding.
    func bind(to sim: Simulator) throws -> (screen: any Screen, input: any HID) {
        if enableCarPlay {
            try sim.externalDisplays().enableCarPlay()
        }
        switch kind {
        case .phone:
            if let panel {
                let display = sim.displays().panel(panel)
                return (display.screen(), display.input())
            }
            return (sim.screen(), sim.input())
        case .carPlay:
            let display = sim.displays()[.carPlay]
            // Fail closed: never open an unbound Screen that would
            // silently stream the phone plane into the CarPlay pane.
            _ = try display.resolve()
            return (display.screen(), display.input())
        }
    }
}
