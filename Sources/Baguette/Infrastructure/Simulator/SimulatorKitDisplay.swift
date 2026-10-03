import Foundation

/// One display plane backed by SimulatorKit ports + Connected Screens.
final class SimulatorKitDisplay: Display, @unchecked Sendable {
    let kind: DisplayKind
    private let udid: String
    private let host: any DeviceHost
    private let enumerateIO: () throws -> String
    private let hinge: any Hinge
    /// A foldable's hardware keys, when the guest tool is there to
    /// press them; see `FoldableInput`.
    private let keys: (any DeviceKeys)?
    /// When set, the lit panel is this one and the hinge is not asked —
    /// see `Displays.panel(_:)`.
    private let pinnedPanel: IntegratedPanel?
    private let lock = NSLock()
    private var cached: DisplayBinding?

    init(
        kind: DisplayKind,
        udid: String,
        host: any DeviceHost,
        enumerateIO: @escaping () throws -> String,
        hinge: any Hinge,
        keys: (any DeviceKeys)? = nil,
        pinnedPanel: IntegratedPanel? = nil
    ) {
        self.kind = kind
        self.udid = udid
        self.host = host
        self.enumerateIO = enumerateIO
        self.hinge = hinge
        self.keys = keys
        self.pinnedPanel = pinnedPanel
    }

    /// Binds the plane. On a foldable this also asks the hinge which
    /// panel is lit (~0.3 s through devicectl); a single-panel device
    /// never pays that, since it has nothing to choose between.
    func resolve() throws -> DisplayBinding {
        let sized = try SimulatorKitFramebufferPorts.sizedPorts(udid: udid, host: host)
        let screens = SimctlIOEnumerate.connectedScreens(from: try enumerateIO())
        let ports = FramebufferPortSnapshots.assigningScreenIds(
            ports: sized,
            screens: screens
        )
        let litPanel: IntegratedPanel = pinnedPanel
            ?? (IntegratedPanels.several(in: sized) ? (hinge.angle()?.litPanel ?? .primary) : .primary)
        let binding = try ConnectedScreens.binding(kind: kind, ports: ports, litPanel: litPanel)
        lock.lock()
        cached = binding
        lock.unlock()
        return binding
    }

    /// The panel an observation is read from, as a binding plus the
    /// `AXScreen` that describes it. Reads the connected screens afresh
    /// and, on a foldable, samples the guest hinge directly: a shared
    /// hinge watch can hold a stale value, and an observation that
    /// names the wrong panel would send input to the dark one.
    private func observedBinding() throws -> (binding: DisplayBinding, screen: AXScreen, multiplePanels: Bool) {
        guard kind == .phone, pinnedPanel == nil,
            let device = host.resolveDevice(udid: udid)
        else { throw ObservedScreenError.unavailable }
        let ports = try SimulatorKitFramebufferPorts.sizedPorts(udid: udid, host: host)
        let screens = SimctlIOEnumerate.connectedScreens(from: try enumerateIO())
        let multiple = screens.filter { $0.screenType == .integrated }.count > 1
        let angle = multiple ? DevicectlHinge(udid: udid).angle() : nil
        let observed = try ConnectedScreens.observedPhone(ports: ports, screens: screens, angle: angle)
        let binding = observed.binding
        guard let points = binding.pointSize(scale: observed.scale) else {
            throw ObservedScreenError.unavailable
        }
        let orientation = try SimulatorKitScreenOrientation.read(device: device, screenID: binding.connectedScreenId)
        return (
            binding,
            AXScreen(
                width: points.width, height: points.height, orientation: orientation,
                target: ScreenTarget(
                    screenId: binding.connectedScreenId, litPanel: binding.panel, pixelSize: binding.size)
            ), observed.multiplePanels
        )
    }

    func observedScreen() throws -> AXScreen { try observedBinding().screen }

    func screen() -> any Screen {
        // Prefer a fresh resolve; fall back to the last successful
        // binding so a transient probe miss after bind() doesn't open
        // an unbound phone stream under a CarPlay label.
        let binding = (try? resolve()) ?? cachedBinding()
        return SimulatorKitScreen(udid: udid, host: host, binding: binding)
    }

    /// Input for this plane.
    ///
    /// A target is a **registration** — the key some create-service
    /// message stored a service under — so nothing about it goes stale
    /// and it is not re-derived per gesture. (There was a version that
    /// did, putting a `simctl io enumerate` subprocess in front of every
    /// move of a drag. It is gone.) Dispatching to a panel that has since
    /// detached is harmless: the service stays registered and the event
    /// lands nowhere. Only an *unregistered* target kills the guest, and
    /// this cannot produce one: the built-in slot is always there, and a
    /// panel id only comes from a Connected Screens record marked
    /// Integrated.
    ///
    /// Which registration the phone plane addresses depends on how many
    /// panels the device has — see `boundPanelScreenId`.
    ///
    /// On a foldable the hardware keys go to the guest as well — the
    /// legacy press lands on a touchscreen service there and SpringBoard
    /// ignores it — so the panel's input is wrapped in `FoldableInput`.
    func input() -> any Input {
        let panel = boundPanelScreenId()
        let target = DisplayTouchTarget.resolve(
            kind: kind,
            connectedScreenId: panel,
            derive: { _ in nil },
            override: DisplayTouchTarget.parseOverride(
                ProcessInfo.processInfo.environment["BAGUETTE_CARPLAY_TARGET"]
            )
        ) ?? IndigoHIDTouchTarget.phone
        let touches = IndigoHIDInput(udid: udid, host: host, touchTarget: target, plane: kind)
        guard panel != nil, let keys else { return touches }
        return FoldableInput(touches: touches, keys: keys)
    }

    /// The phone plane's panel, when the device has more than one.
    ///
    /// A foldable's panels are all created built-in, and they share the
    /// built-in digitizer slot `0x32` — last one created owns it, which
    /// on iPhone Duo is the unfolded panel. Only there is the *lit*
    /// panel's own registration worth the round-trips (`simctl io
    /// enumerate` ~130 ms, the hinge ~300 ms). One panel — every other
    /// device — is answered by the in-process port walk alone and keeps
    /// the slot, so a one-shot tap pays nothing new.
    private func boundPanelScreenId() -> UInt32? {
        guard kind == .phone,
              let sized = try? SimulatorKitFramebufferPorts.sizedPorts(udid: udid, host: host),
              IntegratedPanels.several(in: sized),
              let binding = try? resolve()
        else { return nil }
        return binding.connectedScreenId
    }

    private func cachedBinding() -> DisplayBinding? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }
}
