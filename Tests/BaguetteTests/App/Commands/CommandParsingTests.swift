import Testing
import ArgumentParser
@testable import Baguette

/// Parses each subcommand from argv and asserts the @Option/@OptionGroup
/// wiring + CommandConfiguration metadata. `run()` itself talks to
/// CoreSimulators / stdin / signals, so it stays out of coverage by
/// design — these tests only pin the structure.
@Suite("CommandParsing")
struct CommandParsingTests {

    // MARK: - root

    @Test func `should offer every subcommand from the baguette root`() {
        let cfg = Baguette.configuration
        #expect(cfg.commandName == "baguette")
        let names = cfg.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == [
            "list", "boot", "shutdown", "launch", "input", "stream",
            "tap", "double-tap", "swipe", "pinch", "pan", "press",
            "key", "type", "fill", "paste", "clipboard",
            "chrome", "screenshot", "record", "render-3d", "describe-ui", "logs", "serve",
            "orientation", "hinge", "shake", "status-bar", "location", "motion", "network",
            "install", "add-media",
            "openurl", "schemes", "notify",
            "plugin", "bakery", "diag-digitizer-trackpad", "lifetime", "interface",
            "heal", "defaults",
        ])
    }

    // MARK: - hinge

    @Test func `should let hinge take a pose or an angle, and a sweep duration`() throws {
        let pose = try HingeCLICommand.parse(["--udid", "U", "--pose", "open"])
        #expect(pose.pose == "open" && pose.angle == nil)
        let angle = try HingeCLICommand.parse(["--udid", "U", "--angle", "95", "--duration", "1.2"])
        #expect(angle.angle == "95" && angle.duration == "1.2")
        let read = try HingeCLICommand.parse(["--udid", "U"])
        #expect(read.pose == nil && read.angle == nil)
    }

    // MARK: - notify

    @Test func `should notify the app named by --bundle-id with the payload in --file`() throws {
        let cmd = try NotifyCommand.parse(["--udid", "U", "--bundle-id", "com.example.app", "--file", "n.json"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.bundleId == "com.example.app")
        #expect(cmd.file == "n.json")
        #expect(cmd.stdin == false)
        #expect(NotifyCommand.configuration.commandName == "notify")
    }

    @Test func `should notify with the payload on stdin, reporting as JSON`() throws {
        let cmd = try NotifyCommand.parse(["--udid", "U", "--stdin", "--json"])
        #expect(cmd.stdin)
        #expect(cmd.json)
        #expect(cmd.bundleId == nil)
    }

    @Test func `should reject notify when no payload source is given`() {
        #expect(throws: (any Error).self) { try NotifyCommand.parse(["--udid", "U", "--bundle-id", "a"]) }
    }

    @Test func `should reject notify when given both a file and stdin`() {
        #expect(throws: (any Error).self) {
            try NotifyCommand.parse(["--udid", "U", "--file", "n.json", "--stdin"])
        }
    }

    // MARK: - openurl / schemes

    @Test func `should open the url given to openurl on the chosen simulator`() throws {
        let cmd = try OpenURLCommand.parse(["--udid", "U", "myapp://profile/42"])
        #expect(cmd.url == "myapp://profile/42")
        // The udid too, or this passes unchanged if `DeviceOption` ever
        // stops binding for this command — which is the wiring the test
        // exists to pin.
        #expect(cmd.options.udid == "U")
        #expect(OpenURLCommand.configuration.commandName == "openurl")
    }

    @Test func `should reject openurl when no url is given`() {
        #expect(throws: (any Error).self) { try OpenURLCommand.parse(["--udid", "U"]) }
    }

    @Test func `should take the simulator for schemes from --udid`() throws {
        let cmd = try SchemesCommand.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(SchemesCommand.configuration.commandName == "schemes")
    }

    @Test func `should offer the whole source lifecycle under bakery`() {
        // Pinned so a verb can't be added without a deliberate edit
        // here — `outdated` in particular is the only way a user learns
        // a trusted source has moved, and it must not quietly vanish.
        #expect(
            Set(BakeryCommand.configuration.subcommands.map { $0.configuration.commandName })
                == Set(["add", "list", "outdated", "remove", "update"])
        )
    }

    @Test func `should report the baguette version from the root`() {
        #expect(Baguette.configuration.version == baguetteVersion)
        #expect(!baguetteVersion.isEmpty)
    }

    // MARK: - list

    @Test func `should take the device set for list from --device-set`() throws {
        let cmd = try ListCommand.parse(["--device-set", "/tmp/set"])
        #expect(cmd.deviceSet == "/tmp/set")
        #expect(ListCommand.configuration.commandName == "list")
    }

    @Test func `should list the default device set as text when list has no flags`() throws {
        let cmd = try ListCommand.parse([])
        #expect(cmd.deviceSet == nil)
        #expect(cmd.json == false)
    }

    @Test func `should list as JSON when --json is given`() throws {
        let cmd = try ListCommand.parse(["--json"])
        #expect(cmd.json == true)
    }

    // MARK: - boot / shutdown share DeviceOption

    @Test func `should take the simulator to boot from --udid`() throws {
        let cmd = try BootCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.options.deviceSet == nil)
        #expect(BootCommand.configuration.commandName == "boot")
    }

    @Test func `should reject boot when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try BootCommand.parse([])
        }
    }

    @Test func `should heal the input surface on boot unless --no-heal is given`() throws {
        #expect(try BootCommand.parse(["--udid", "ABC"]).noHeal == false)
        #expect(try BootCommand.parse(["--udid", "ABC", "--no-heal"]).noHeal == true)
    }

    // MARK: - heal

    @Test func `should take the simulator to heal from --udid and reject heal without it`() throws {
        let cmd = try HealCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(HealCommand.configuration.commandName == "heal")
        #expect(throws: (any Error).self) {
            try HealCommand.parse([])
        }
    }

    @Test func `should take the simulator and device set to shut down from --udid and --device-set`() throws {
        let cmd = try ShutdownCommand.parse([
            "--udid", "XYZ", "--device-set", "/var/sims",
        ])
        #expect(cmd.options.udid == "XYZ")
        #expect(cmd.options.deviceSet == "/var/sims")
        #expect(ShutdownCommand.configuration.commandName == "shutdown")
    }

    // MARK: - lifetime

    @Test func `should only read the lifetime policy when lifetime has no flags`() throws {
        let cmd = try LifetimeCommand.parse([])
        #expect(cmd.detach == false)
        #expect(cmd.shutdown == false)
        #expect(LifetimeCommand.configuration.commandName == "lifetime")
    }

    @Test func `should set the lifetime policy to detach on --detach`() throws {
        let cmd = try LifetimeCommand.parse(["--detach"])
        #expect(cmd.detach == true)
        #expect(cmd.shutdown == false)
    }

    @Test func `should set the lifetime policy to shut down on --shutdown`() throws {
        let cmd = try LifetimeCommand.parse(["--shutdown"])
        #expect(cmd.shutdown == true)
        #expect(cmd.detach == false)
    }

    @Test func `should reject lifetime when both --detach and --shutdown are given`() {
        // --detach and --shutdown are opposite ends of one policy;
        // accepting both would silently pick one.
        #expect(throws: (any Error).self) {
            try LifetimeCommand.parse(["--detach", "--shutdown"])
        }
    }

    @Test func `should reject a --udid on lifetime because the policy is machine-wide`() {
        // These are Simulator.app's preferences, not a device's, so a
        // per-device flag would be a lie.
        #expect(throws: (any Error).self) {
            try LifetimeCommand.parse(["--udid", "ABC"])
        }
    }

    // MARK: - input

    @Test func `should take the simulator for input from --udid`() throws {
        let cmd = try InputCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(InputCommand.configuration.commandName == "input")
    }

    // MARK: - orientation

    @Test func `should rotate to portrait on orientation portrait`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "portrait"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.value == .portrait)
        #expect(OrientationCommand.configuration.commandName == "orientation")
    }

    @Test func `should rotate to landscape-left on orientation landscape-left`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "landscape-left"])
        #expect(cmd.value == .landscapeLeft)
    }

    @Test func `should rotate to landscape-right on orientation landscape-right`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "landscape-right"])
        #expect(cmd.value == .landscapeRight)
    }

    @Test func `should rotate to portrait-upside-down on orientation portrait-upside-down`() throws {
        let cmd = try OrientationCommand.parse(["--udid", "U", "portrait-upside-down"])
        #expect(cmd.value == .portraitUpsideDown)
    }

    @Test func `should reject an unknown orientation`() {
        #expect(throws: (any Error).self) {
            try OrientationCommand.parse(["--udid", "U", "sideways"])
        }
    }

    @Test func `should reject orientation when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try OrientationCommand.parse(["portrait"])
        }
    }

    // MARK: - shake

    @Test func `should take the simulator to shake from --udid`() throws {
        let cmd = try ShakeCommand.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ShakeCommand.configuration.commandName == "shake")
    }

    @Test func `should reject shake when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try ShakeCommand.parse([])
        }
    }

    // MARK: - status-bar

    @Test func `should offer override and clear under status-bar`() {
        let names = StatusBarCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["override", "clear"])
        #expect(StatusBarCommand.configuration.commandName == "status-bar")
    }

    // MARK: - interface

    @Test func `should offer one interface subcommand per simctl ui option`() {
        let names = InterfaceCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["appearance", "contrast", "text-size"])
        #expect(InterfaceCommand.configuration.commandName == "interface")
    }

    @Test func `should set the interface appearance to the value given`() throws {
        let cmd = try InterfaceCommand.Appearance.parse(["--udid", "U", "dark"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.value == .dark)
    }

    @Test func `should read the interface appearance when no value is given`() throws {
        // The same leaf reads and writes, matching `simctl ui` itself —
        // no separate `get` verb to remember.
        let cmd = try InterfaceCommand.Appearance.parse(["--udid", "U"])
        #expect(cmd.value == nil)
    }

    @Test func `should reject an interface appearance that can only be read back`() {
        // "unknown" is an answer simctl gives, not one it takes.
        #expect(throws: (any Error).self) {
            try InterfaceCommand.Appearance.parse(["--udid", "U", "unknown"])
        }
    }

    @Test func `should set interface contrast to enabled or disabled, or read it when no value is given`() throws {
        #expect(try InterfaceCommand.Contrast.parse(["--udid", "U", "enabled"]).value == .enabled)
        #expect(try InterfaceCommand.Contrast.parse(["--udid", "U", "disabled"]).value == .disabled)
        #expect(try InterfaceCommand.Contrast.parse(["--udid", "U"]).value == nil)
    }

    @Test func `should let interface text-size take a category or a relative step`() throws {
        #expect(
            try InterfaceCommand.TextSize.parse(["--udid", "U", "accessibility-large"]).value
                == .size(.accessibilityLarge)
        )
        #expect(try InterfaceCommand.TextSize.parse(["--udid", "U", "increment"]).value == .increment)
        #expect(try InterfaceCommand.TextSize.parse(["--udid", "U", "decrement"]).value == .decrement)
        #expect(try InterfaceCommand.TextSize.parse(["--udid", "U"]).value == nil)
    }

    @Test func `should reject an interface text-size that is not a category`() {
        #expect(throws: (any Error).self) {
            try InterfaceCommand.TextSize.parse(["--udid", "U", "gigantic"])
        }
    }

    @Test func `should override every status-bar field given on the command line`() throws {
        let cmd = try StatusBarCommand.Override.parse([
            "--udid", "U",
            "--time", "9:41",
            "--operator-name", "Baguette",
            "--data-network", "5g",
            "--wifi-mode", "active",
            "--wifi-bars", "3",
            "--cellular-mode", "active",
            "--cellular-bars", "4",
            "--battery-state", "charged",
            "--battery-level", "68",
        ])
        #expect(cmd.options.udid == "U")
        #expect(cmd.override == StatusBarOverride(
            time: "9:41",
            operatorName: "Baguette",
            dataNetwork: .fiveG,
            wifiMode: .active,
            wifiBars: 3,
            cellularMode: .active,
            cellularBars: 4,
            batteryState: .charged,
            batteryLevel: 68
        ))
    }

    @Test func `should build an empty status-bar override when no fields are given`() throws {
        let cmd = try StatusBarCommand.Override.parse(["--udid", "U"])
        #expect(cmd.override.isEmpty)
    }

    @Test func `should reject a status-bar override with an unknown data network`() {
        #expect(throws: (any Error).self) {
            try StatusBarCommand.Override.parse(["--udid", "U", "--data-network", "6g"])
        }
    }

    @Test func `should reject status-bar override when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try StatusBarCommand.Override.parse(["--battery-level", "50"])
        }
    }

    @Test func `should take the simulator for status-bar clear from --udid`() throws {
        let cmd = try StatusBarCommand.Clear.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(StatusBarCommand.Clear.configuration.commandName == "clear")
    }

    // MARK: - motion

    @Test func `should offer start, set and stop under motion`() {
        let names = MotionCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["start", "set", "stop"])
        #expect(MotionCommand.configuration.commandName == "motion")
    }

    @Test func `should start motion with the activity given`() throws {
        let cmd = try MotionCommand.Start.parse(["--udid", "U", "--activity", "walking"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.kind == .walking)
    }

    @Test func `should start walking at a walking pace when motion start has no flags`() throws {
        // The overwhelmingly common case is "make this app think I'm
        // walking", so it needs no flags at all.
        let cmd = try MotionCommand.Start.parse(["--udid", "U"])
        #expect(cmd.kind == .walking)
        #expect(cmd.resolvedSpeed == 1.4)
    }

    @Test func `should start motion at the activity's own speed when no speed is given`() throws {
        // Each kind has a representative speed — the same presets the
        // browser's Walk mode offers — so `--activity running` alone means
        // a plausible run rather than a run at 0 m/s.
        #expect(try MotionCommand.Start.parse(
            ["--udid", "U", "--activity", "running"]).resolvedSpeed == 3.5)
        #expect(try MotionCommand.Start.parse(
            ["--udid", "U", "--activity", "automotive"]).resolvedSpeed == 13.4)
        #expect(try MotionCommand.Start.parse(
            ["--udid", "U", "--activity", "stationary"]).resolvedSpeed == 0)
    }

    @Test func `should start motion at the speed given`() throws {
        let cmd = try MotionCommand.Start.parse(
            ["--udid", "U", "--activity", "walking", "--speed", "2.2"])
        #expect(cmd.resolvedSpeed == 2.2)
    }

    @Test func `should reject a negative motion speed`() {
        // A negative speed classifies as `unknown`, so it would arm a session
        // reporting no motion — a confusing way to spell "invalid input".
        #expect(throws: (any Error).self) {
            try MotionCommand.Start.parse(["--udid", "U", "--speed", "-1"])
        }
    }

    @Test func `should reject an unknown motion activity`() {
        // Failing loudly beats silently reporting `unknown` motion.
        #expect(throws: (any Error).self) {
            try MotionCommand.Start.parse(["--udid", "U", "--activity", "swimming"])
        }
    }

    @Test func `should reject motion stop when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try MotionCommand.Stop.parse([])
        }
    }

    // MARK: - network

    @Test func `should offer set, clear and status under network`() {
        let names = NetworkCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["set", "clear", "status"])
        #expect(NetworkCommand.configuration.commandName == "network")
    }

    @Test func `should report the current network condition when no network verb is named`() {
        // A forgotten throttle reads as "the app is slow", days later. The
        // cheapest defence is that the bare command answers "is anything
        // on?" rather than printing usage.
        let fallback = NetworkCommand.configuration.defaultSubcommand
        #expect(fallback?.configuration.commandName == "status")
    }

    @Test func `should set the network to a named preset`() throws {
        let cmd = try NetworkCommand.Set.parse(["--udid", "U", "--profile", "3g"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.condition.condition == NetworkProfile.threeG.condition)
    }

    @Test func `should set the network from explicit latency, bandwidth and loss`() throws {
        let cmd = try NetworkCommand.Set.parse(
            ["--udid", "U", "--latency", "300", "--bandwidth", "400", "--loss", "5"])
        #expect(cmd.condition.condition?.latencyMs == 300)
        #expect(cmd.condition.condition?.bandwidthKbps == 400)
        #expect(cmd.condition.condition?.lossPercent == 5)
    }

    @Test func `should leave the network bandwidth unmetered when none is given`() throws {
        // "Make every request wait, but let bytes arrive at full speed" is
        // a normal thing to ask for, and must not become a bandwidth of 0.
        let cmd = try NetworkCommand.Set.parse(["--udid", "U", "--latency", "300"])
        #expect(cmd.condition.condition?.bandwidthKbps == nil)
    }

    @Test func `should take the network offline on --offline`() throws {
        let cmd = try NetworkCommand.Set.parse(["--udid", "U", "--offline"])
        #expect(cmd.condition.condition == .offline)
    }

    @Test func `should reject a network preset nobody has heard of`() {
        // A silent fallback would arm a condition nobody asked for, and the
        // afternoon would go on wondering why the app was slow.
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--profile", "2g"])
        }
    }

    @Test func `should refuse to mix a network preset with any other setting`() {
        // One source of truth per invocation. "3g but lossier" reads like
        // it should work, and deciding whether the preset or the flag wins
        // is a coin toss the user would have to remember.
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--profile", "3g", "--loss", "20"])
        }
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--profile", "3g", "--offline"])
        }
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--offline", "--latency", "300"])
        }
    }

    @Test func `should refuse a network set that would condition nothing`() {
        // Arming the dylib while changing nothing costs an app relaunch and
        // achieves nothing visible — far more likely a forgotten flag than
        // an intention.
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U"])
        }
    }

    @Test func `should reject network numbers that describe no network`() {
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--latency", "-1"])
        }
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--loss", "150"])
        }
        #expect(throws: (any Error).self) {
            try NetworkCommand.Set.parse(["--udid", "U", "--bandwidth", "0"])
        }
    }

    @Test func `should reject network clear when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try NetworkCommand.Clear.parse([])
        }
    }

    // MARK: - location

    @Test func `should offer set, start, walk and clear under location`() {
        let names = LocationCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["set", "start", "walk", "clear"])
        #expect(LocationCommand.configuration.commandName == "location")
    }

    @Test func `should set the location to the lat,lon given`() throws {
        let cmd = try LocationCommand.Set.parse(["--udid", "U", "37.3318,-122.0312"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.coordinate == Coordinate(latitude: 37.3318, longitude: -122.0312))
        #expect(LocationCommand.Set.configuration.commandName == "set")
    }

    @Test func `should set no location when the coordinate is out of range`() throws {
        let cmd = try LocationCommand.Set.parse(["--udid", "U", "120,0"])
        #expect(cmd.coordinate == nil)
    }

    @Test func `should reject location set when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try LocationCommand.Set.parse(["1,2"])
        }
    }

    @Test func `should start a location route through the waypoints at the speed and distance given`() throws {
        let cmd = try LocationCommand.Start.parse([
            "--udid", "U", "--speed", "260", "--distance", "1000",
            "37.6,-122.4", "40.6,-73.8",
        ])
        #expect(cmd.route == LocationRoute(
            waypoints: [
                Coordinate(latitude: 37.6, longitude: -122.4)!,
                Coordinate(latitude: 40.6, longitude: -73.8)!,
            ],
            speed: 260, distance: 1000
        ))
    }

    @Test func `should start no location route when only one waypoint is given`() throws {
        let cmd = try LocationCommand.Start.parse(["--udid", "U", "37.6,-122.4"])
        #expect(cmd.route == nil)
    }

    @Test func `should walk the location from an origin at the bearing and speed given`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "90", "--speed", "5", "37.3349,-122.0090",
        ])
        #expect(cmd.options.udid == "U")
        #expect(cmd.walk == LocationWalk(
            origin: Coordinate(latitude: 37.3349, longitude: -122.0090)!,
            bearing: Bearing(degrees: 90),
            speed: 5
        ))
        #expect(LocationCommand.Walk.configuration.commandName == "walk")
    }

    @Test func `should bring a walk bearing off the compass circle back onto it`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "450", "--speed", "5", "1,2",
        ])
        #expect(cmd.walk?.bearing == Bearing(degrees: 90))
    }

    @Test func `should not walk the location when the speed is not positive`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "0", "--speed", "0", "1,2",
        ])
        #expect(cmd.walk == nil)
    }

    @Test func `should not walk the location from an out-of-range origin`() throws {
        let cmd = try LocationCommand.Walk.parse([
            "--udid", "U", "--bearing", "0", "--speed", "5", "120,0",
        ])
        #expect(cmd.walk == nil)
    }

    @Test func `should take the simulator for location clear from --udid`() throws {
        let cmd = try LocationCommand.Clear.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(LocationCommand.Clear.configuration.commandName == "clear")
    }

    // MARK: - paste

    @Test func `should paste the text given and press Cmd+V by default`() throws {
        let cmd = try PasteCommand.parse(["--udid", "U", "--text", "héllo 🥖"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.text == "héllo 🥖")
        #expect(cmd.press == true)
        #expect(PasteCommand.configuration.commandName == "paste")
    }

    @Test func `should paste without pressing Cmd+V when --no-press is given`() throws {
        let cmd = try PasteCommand.parse(["--udid", "U", "--text", "x", "--no-press"])
        #expect(cmd.press == false)
    }

    @Test func `should reject paste when --text is missing`() {
        #expect(throws: (any Error).self) {
            try PasteCommand.parse(["--udid", "U"])
        }
    }

    @Test func `should reject paste when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try PasteCommand.parse(["--text", "x"])
        }
    }

    // MARK: - clipboard

    @Test func `should offer get, sync and copy under clipboard`() {
        let names = ClipboardCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == ["get", "sync", "copy"])
        #expect(ClipboardCommand.configuration.commandName == "clipboard")
    }

    @Test func `should take the simulator for clipboard copy from --udid`() throws {
        let cmd = try ClipboardCommand.Copy.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ClipboardCommand.Copy.configuration.commandName == "copy")
    }

    @Test func `should take the simulator for clipboard get from --udid`() throws {
        let cmd = try ClipboardCommand.Get.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ClipboardCommand.Get.configuration.commandName == "get")
    }

    @Test func `should take the simulator for clipboard sync from --udid`() throws {
        let cmd = try ClipboardCommand.Sync.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(ClipboardCommand.Sync.configuration.commandName == "sync")
    }

    // MARK: - install / add-media

    @Test func `should install the file at the path given on the chosen simulator`() throws {
        let cmd = try InstallCommand.parse(["--udid", "U", "/tmp/MyApp.ipa"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.path == "/tmp/MyApp.ipa")
        #expect(InstallCommand.configuration.commandName == "install")
    }

    @Test func `should reject install when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try InstallCommand.parse(["/tmp/MyApp.ipa"])
        }
    }

    @Test func `should reject install when no path is given`() {
        #expect(throws: (any Error).self) {
            try InstallCommand.parse(["--udid", "U"])
        }
    }

    @Test func `should add the media file at the path given to the chosen simulator`() throws {
        let cmd = try AddMediaCommand.parse(["--udid", "U", "/tmp/clip.mov"])
        #expect(cmd.options.udid == "U")
        #expect(cmd.path == "/tmp/clip.mov")
        #expect(AddMediaCommand.configuration.commandName == "add-media")
    }

    @Test func `should reject add-media when --udid is missing`() {
        #expect(throws: (any Error).self) {
            try AddMediaCommand.parse(["/tmp/clip.mov"])
        }
    }

    // MARK: - diag-digitizer-trackpad

    @Test func `should take the simulator for diag-digitizer-trackpad from --udid`() throws {
        let cmd = try DiagDigitizerTrackpadCommand.parse(["--udid", "U"])
        #expect(cmd.options.udid == "U")
        #expect(DiagDigitizerTrackpadCommand.configuration.commandName == "diag-digitizer-trackpad")
    }

    // MARK: - stream

    @Test func `should stream mjpeg at 60 fps with the default bitrate and scale when no knobs are given`() throws {
        let cmd = try StreamCommand.parse(["--udid", "ABC"])
        #expect(cmd.format == "mjpeg")
        #expect(cmd.fps == 60)
        #expect(cmd.quality == 0.70)
        #expect(cmd.bitrate == StreamConfig.default.bitrateBps)
        #expect(cmd.scale == StreamConfig.default.scale)
        #expect(StreamCommand.configuration.commandName == "stream")
    }

    @Test func `should stream with every tunable knob given`() throws {
        let cmd = try StreamCommand.parse([
            "--udid", "ABC",
            "--format", "avcc",
            "--fps", "30",
            "--quality", "0.9",
            "--bitrate", "8000000",
            "--scale", "2",
        ])
        #expect(cmd.format == "avcc")
        #expect(cmd.fps == 30)
        #expect(cmd.quality == 0.9)
        #expect(cmd.bitrate == 8_000_000)
        #expect(cmd.scale == 2)
    }

    // MARK: - gesture commands

    @Test func `should tap at the point, screen size and duration given`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "10", "--y", "20",
            "--width", "390", "--height", "844",
            "--duration", "0.1",
        ])
        #expect(cmd.x == 10 && cmd.y == 20)
        #expect(cmd.width == 390 && cmd.height == 844)
        #expect(cmd.duration == 0.1)
        #expect(TapCommand.configuration.commandName == "tap")
    }

    @Test func `should hold a tap for 0.05 seconds when no duration is given`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.duration == 0.05)
    }

    @Test func `should double-tap at the point, screen size, interval and duration given`() throws {
        let cmd = try DoubleTapCommand.parse([
            "--udid", "ABC",
            "--x", "220", "--y", "480",
            "--width", "402", "--height", "874",
            "--interval", "0.12",
            "--duration", "0.05",
        ])
        #expect(cmd.x == 220 && cmd.y == 480)
        #expect(cmd.width == 402 && cmd.height == 874)
        #expect(cmd.interval == 0.12)
        #expect(cmd.duration == 0.05)
        #expect(DoubleTapCommand.configuration.commandName == "double-tap")
    }

    @Test func `should double-tap at the observed-working cadence when no interval or duration is given`() throws {
        let cmd = try DoubleTapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.interval == 0.05)
        #expect(cmd.duration == 0.08)
    }

    @Test func `should swipe from start to end on the screen size given over 0.25 seconds by default`() throws {
        let cmd = try SwipeCommand.parse([
            "--udid", "ABC",
            "--start-x", "0", "--start-y", "0",
            "--end-x", "100", "--end-y", "200",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.startX == 0 && cmd.startY == 0)
        #expect(cmd.endX == 100 && cmd.endY == 200)
        #expect(cmd.duration == 0.25)
        #expect(SwipeCommand.configuration.commandName == "swipe")
    }

    @Test func `should pinch around the centre from the start spread to the end spread given`() throws {
        let cmd = try PinchCommand.parse([
            "--udid", "ABC",
            "--cx", "100", "--cy", "200",
            "--start-spread", "50", "--end-spread", "150",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.cx == 100 && cmd.cy == 200)
        #expect(cmd.startSpread == 50 && cmd.endSpread == 150)
        #expect(cmd.duration == 0.6)
        #expect(PinchCommand.configuration.commandName == "pinch")
    }

    @Test func `should pan two fingers by the delta given`() throws {
        let cmd = try PanCommand.parse([
            "--udid", "ABC",
            "--x1", "10", "--y1", "20",
            "--x2", "30", "--y2", "40",
            "--dx", "5", "--dy=-5",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.x1 == 10 && cmd.y1 == 20)
        #expect(cmd.x2 == 30 && cmd.y2 == 40)
        #expect(cmd.dx == 5 && cmd.dy == -5)
        #expect(cmd.duration == 0.5)
        #expect(PanCommand.configuration.commandName == "pan")
    }

    @Test func `should press the button given`() throws {
        let cmd = try PressCommand.parse(["--udid", "ABC", "--button", "home"])
        #expect(cmd.button == "home")
        #expect(PressCommand.configuration.commandName == "press")
    }

    // MARK: - screenshot

    @Test func `should take a screenshot to stdout at quality 0.85 and scale 1 by default`() throws {
        let cmd = try ScreenshotCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.output == nil)
        #expect(cmd.quality == 0.85)
        #expect(cmd.scale == 1)
        #expect(ScreenshotCommand.configuration.commandName == "screenshot")
    }

    @Test func `should take a screenshot with the output, quality and scale given`() throws {
        let cmd = try ScreenshotCommand.parse([
            "--udid", "ABC",
            "--output", "/tmp/x.jpg",
            "--quality", "0.5",
            "--scale", "2",
        ])
        #expect(cmd.output == "/tmp/x.jpg")
        #expect(cmd.quality == 0.5)
        #expect(cmd.scale == 2)
    }

    // MARK: - render-3d

    @Test func `should render a live simulator in 3D with every render option given`() throws {
        let cmd = try Render3DCommand.parse([
            "--udid", "ABC",
            "--variant", "finish=space-black",
            "--variant", "keyboard=iso",
            "--rotation=-30,45,30",
            "--size", "1200x900",
            "--fit", "contain",
            "--background", "#112233",
            "--screen-glass",
            "--output", "device.png",
        ])

        #expect(cmd.udid == "ABC")
        #expect(cmd.screen == nil)
        #expect(cmd.screenGlass == true)
        #expect(cmd.variants == ["finish=space-black", "keyboard=iso"])
        #expect(cmd.rotation == "-30,45,30")
        #expect(cmd.size == "1200x900")
        #expect(cmd.fit == "contain")
        #expect(cmd.background == "#112233")
        #expect(cmd.output == "device.png")
    }

    @Test func `should render an existing screen image in 3D on the device model given`() throws {
        let cmd = try Render3DCommand.parse([
            "--screen", "screen.png", "--device", "iphone-17-pro",
        ])
        #expect(cmd.screen == "screen.png")
        #expect(cmd.device == "iphone-17-pro")
        #expect(cmd.screenGlass == false)
    }

    @Test func `should reject render-3d given both a simulator and a screen image`() {
        #expect(throws: (any Error).self) {
            try Render3DCommand.parse([
                "--udid", "ABC", "--screen", "screen.png",
                "--device", "iphone-17-pro",
            ])
        }
    }

    // MARK: - describe-ui

    @Test func `should describe the full UI tree to stdout by default`() throws {
        let cmd = try DescribeUICommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.x == nil && cmd.y == nil)
        #expect(cmd.output == nil)
        #expect(DescribeUICommand.configuration.commandName == "describe-ui")
    }

    @Test func `should fill the named field with the text given`() throws {
        let cmd = try FillCommand.parse(["--udid", "ABC", "--label", "email", "--text", "gary"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.label == "email")
        #expect(cmd.text == "gary")
    }

    @Test func `should refuse a fill with no field named`() {
        #expect(throws: (any Error).self) {
            try FillCommand.parse(["--udid", "ABC", "--text", "gary"])
        }
    }

    @Test func `should refuse a fill with no text given`() {
        #expect(throws: (any Error).self) {
            try FillCommand.parse(["--udid", "ABC", "--label", "email"])
        }
    }

    @Test func `should reach fill from the root command`() throws {
        #expect(Baguette.configuration.subcommands.contains { $0 == FillCommand.self })
    }

    @Test func `should read the screen short when asked`() throws {
        let cmd = try DescribeUICommand.parse(["--udid", "ABC", "--short"])
        #expect(cmd.short == true)
    }

    @Test func `should refuse a short read at a point on the command line`() {
        #expect(throws: (any Error).self) {
            try DescribeUICommand.parse(["--udid", "ABC", "--short", "--x", "1", "--y", "2"])
        }
    }

    @Test func `should refuse a point with only one coordinate on the command line`() {
        #expect(throws: (any Error).self) {
            try DescribeUICommand.parse(["--udid", "ABC", "--x", "1"])
        }
    }

    @Test func `should describe the UI at the point given into the output file given`() throws {
        let cmd = try DescribeUICommand.parse([
            "--udid", "ABC",
            "--x", "120", "--y", "400",
            "--output", "/tmp/tree.json",
        ])
        #expect(cmd.x == 120 && cmd.y == 400)
        #expect(cmd.output == "/tmp/tree.json")
    }

    // MARK: - help lists what the command accepts

    @Test func `should list only the formats a stream accepts in the --format help`() {
        let help = StreamCommand.helpMessage(columns: 400)
        #expect(help.contains("Output format: mjpeg | avcc"))
        #expect(!help.contains("h264"))
    }

    @Test func `should list only the levels the simulator log accepts in the --level help`() {
        let help = LogsCommand.helpMessage(columns: 400)
        #expect(help.contains("Minimum log level: default | info | debug"))
        #expect(!help.contains("notice"))
    }

    @Test func `should list every style the log stream accepts in the --style help`() {
        let help = LogsCommand.helpMessage(columns: 400)
        #expect(help.contains("Output style: default | compact | json | syslog | ndjson"))
    }

    // MARK: - logs

    @Test func `should stream info-level logs in the default style when only --udid is given`() throws {
        let cmd = try LogsCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.level == "info")
        #expect(cmd.style == "default")
        #expect(cmd.predicate == nil)
        #expect(cmd.bundleId == nil)
        #expect(LogsCommand.configuration.commandName == "logs")
    }

    @Test func `should stream logs with the level, style, predicate and bundle id given`() throws {
        let cmd = try LogsCommand.parse([
            "--udid", "ABC",
            "--level", "debug",
            "--style", "json",
            "--predicate", #"subsystem == "com.apple.UIKit""#,
            "--bundle-id", "com.example.app",
        ])
        #expect(cmd.level == "debug")
        #expect(cmd.style == "json")
        #expect(cmd.predicate == #"subsystem == "com.apple.UIKit""#)
        #expect(cmd.bundleId == "com.example.app")
    }

    // MARK: - serve

    @Test func `should serve on 127.0.0.1:8421 by default`() throws {
        let cmd = try ServeCommand.parse([])
        #expect(cmd.host == "127.0.0.1")
        #expect(cmd.port == 8421)
        #expect(cmd.deviceSet == nil)
        #expect(ServeCommand.configuration.commandName == "serve")
    }

    @Test func `should serve on the host, port and device set given`() throws {
        let cmd = try ServeCommand.parse([
            "--host", "0.0.0.0",
            "--port", "9000",
            "--device-set", "/tmp/sims",
        ])
        #expect(cmd.host == "0.0.0.0")
        #expect(cmd.port == 9000)
        #expect(cmd.deviceSet == "/tmp/sims")
    }

    // MARK: - --display, on both agent-facing surfaces

    /// A malformed `--display` is wrong about the command line itself, so
    /// both commands must reject it at validation — before either goes
    /// looking for a device. `input` used to resolve the simulator first,
    /// which meant an absent udid masked the typo and the operator was
    /// told the wrong thing about which of the two was broken.

    @Test func `should capture the --display plane given in a screenshot, and no plane by default`() throws {
        #expect(try ScreenshotCommand.parse(["--udid", "U"]).display == nil)
        #expect(try ScreenshotCommand.parse(
            ["--udid", "U", "--display", "carplay"]
        ).display == "carplay")
    }

    @Test func `should drive the --display plane given with input, and no plane by default`() throws {
        #expect(try InputCommand.parse(["--udid", "U"]).display == nil)
        #expect(try InputCommand.parse(
            ["--udid", "U", "--display", "carplay"]
        ).display == "carplay")
    }

    @Test func `should reject a screenshot --display that no plane answers to`() {
        #expect(throws: (any Error).self) {
            try ScreenshotCommand.parse(["--udid", "U", "--display", "carply"])
        }
    }

    @Test func `should reject an input --display that no plane answers to`() {
        #expect(throws: (any Error).self) {
            try InputCommand.parse(["--udid", "U", "--display", "carply"])
        }
    }
}
