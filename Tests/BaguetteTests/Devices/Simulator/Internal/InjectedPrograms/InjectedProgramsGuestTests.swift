import Foundation
import Testing

/// The programs baguette runs in the guest, compiled for macOS from
/// `Injected/<Program>/Sources`: what each says to its host, the `serve`
/// loop and `--deadline` they share (`Injected/Shared`), and that each
/// answers only its own verbs.
@Suite("Injected programs in the guest")
struct InjectedProgramsGuestTests {
    private static let injected = RepoRoot.url.appending(path: "Injected")
    private static func sources(_ program: String) -> URL { injected.appending(path: "\(program)/Sources") }
    private static let shared = injected.appending(path: "Shared")

    @Test func `should answer each served command with its status and refuse to act past a deadline`() async throws {
        try await Self.run(compiling: """
        #import "InjectedCommand.h"
        #include <assert.h>
        #include <string.h>
        int main(void) {
          @autoreleasepool {
            char script[] = "angle 10\\n\\n   \\nbogus\\norientation pud\\n";
            FILE *input = fmemopen(script, strlen(script), "r");
            char *text = NULL; size_t length = 0;
            FILE *output = open_memstream(&text, &length);
            NSMutableArray<NSString *> *seen = [NSMutableArray array];
            serveInjectedCommands(input, output, ^int(NSArray<NSString *> *words) {
              [seen addObject:[words componentsJoinedByString:@" "]];
              if ([words.firstObject isEqualToString:@"bogus"]) return 2;
              if ([words.firstObject isEqualToString:@"orientation"]) return 1;
              return 0;
            });
            fclose(output);
            assert([seen isEqualToArray:(@[@"angle 10", @"bogus", @"orientation pud"])]);
            assert(strcmp(text, "done 0\\ndone 2\\ndone 1\\n") == 0);

            double deadline = 0;
            assert(parseInjectedDeadline("1790615000.25", &deadline) && deadline == 1790615000.25);
            const char *invalid[] = {"", "soon", "12x", "inf", "nan"};
            for (int i = 0; i < 5; i++) assert(!parseInjectedDeadline(invalid[i], &deadline));
            assert(injectedDeadlinePassed(1));
            assert(!injectedDeadlinePassed([NSDate date].timeIntervalSince1970 + 3600));
          }
          return 0;
        }
        """, including: [Self.shared])
    }

    @Test func `should take only the orientation picker's native values`() async throws {
        try await Self.run(compiling: """
        #import "OrientationPicker.h"
        #include <assert.h>
        int main(void) {
          @autoreleasepool {
            for (NSString *name in @[@"portrait", @"pud", @"landscape-left", @"landscape-right"]) {
              __block int calls = 0;
              int result = dispatchPickerOrientation(name, ^BOOL(const char *value) {
                ++calls;
                assert([name isEqualToString:@(value)]);
                return YES;
              });
              assert(result == 0 && calls == 1);
              assert(dispatchPickerOrientation(name, ^BOOL(const char *value) { return NO; }) == 1);
            }
            for (NSString *name in @[@"", @"garbage", @"landscapeLeft", @"landscapeRight", @"portraitUpsideDown"]) {
              assert(dispatchPickerOrientation(name, ^BOOL(const char *value) {
                assert(0 && "invalid orientation dispatched"); return YES;
              }) == 2);
            }
          }
          return 0;
        }
        """, including: [Self.sources("DeviceHubControls")])
    }

    /// `button <page> <usage> <ms> [<page> <usage>]…` — trailing pairs are
    /// modifiers, down before the key and up after it in reverse, so a
    /// shifted letter or a Cmd chord types as on a hardware keyboard.
    @Test func `should hold a key's modifiers down around it and release them in reverse`() async throws {
        try await Self.run(compiling: """
        #import "ButtonPress.h"
        #include <assert.h>
        int main(void) {
          @autoreleasepool {
            NSMutableArray<NSString *> *events = [NSMutableArray array];
            __block BOOL refuseDown = NO;
            BOOL (^key)(unsigned, unsigned, BOOL) = ^BOOL(unsigned page, unsigned usage, BOOL down) {
              [events addObject:[NSString stringWithFormat:@"%@ %u %u", down ? @"down" : @"up", page, usage]];
              return !(down && refuseDown && usage == 4);
            };
            void (^hold)(unsigned) = ^(unsigned ms) { [events addObject:[NSString stringWithFormat:@"hold %u", ms]]; };

            assert(pressButton(@[@"12", @"233", @"250"], key, hold) == 0);
            assert([events isEqualToArray:(@[@"down 12 233", @"hold 250", @"up 12 233"])]);

            [events removeAllObjects];
            assert(pressButton(@[@"7", @"4", @"100", @"7", @"225", @"7", @"227"], key, hold) == 0);
            assert([events isEqualToArray:(@[
              @"down 7 225", @"down 7 227", @"down 7 4", @"hold 100", @"up 7 4", @"up 7 227", @"up 7 225"])]);

            // A refused key still releases everything it pressed.
            [events removeAllObjects];
            refuseDown = YES;
            assert(pressButton(@[@"7", @"4", @"100", @"7", @"225"], key, hold) == 1);
            assert([events.lastObject isEqualToString:@"up 7 225"]);

            refuseDown = NO;
            [events removeAllObjects];
            for (NSArray *bad in @[@[], @[@"7", @"4"], @[@"7", @"4", @"100", @"7"], @[@"x", @"4", @"100"]]) {
              assert(pressButton(bad, key, hold) == 2);
            }
            assert(events.count == 0);
          }
          return 0;
        }
        """, including: [Self.sources("HIDButtons")])
    }

    /// `read-angle` and `watch-angle` print each valid sample the guest's
    /// CoreMotion reports as `angle <degrees>`; an invalid one is no reading.
    @Test func `should report each valid hinge sample to the host as an angle line`() async throws {
        try await Self.run(compiling: """
        #import "HingeAngle.h"
        #include <assert.h>
        #include <string.h>
        int main(void) {
          @autoreleasepool {
            char *text = NULL; size_t length = 0;
            FILE *output = open_memstream(&text, &length);
            assert(reportHingeSample(output, 130, YES));
            assert(!reportHingeSample(output, 0, NO));
            assert(reportHingeSample(output, 3.25, YES));
            fclose(output);
            assert(strcmp(text, "angle 130\\nangle 3.25\\n") == 0);
          }
          return 0;
        }
        """, including: [Self.sources("CoreMotionAngle")])
    }

    /// Every case here must exit before the program registers a HID service,
    /// and before it announces a pid to stop.
    static let earlyExits: [(program: String, arguments: [String], status: Int32)] = [
        ("DeviceHubControls", [], 2),
        ("DeviceHubControls", ["orientation"], 2),
        ("DeviceHubControls", ["orientation", "bogus"], 2),
        ("DeviceHubControls", ["orientation", "landscapeLeft"], 2),
        ("DeviceHubControls", ["orientation", "portrait", "extra"], 2),
        ("DeviceHubControls", ["--deadline"], 2),
        ("DeviceHubControls", ["--deadline", "soon", "orientation", "portrait"], 2),
        ("DeviceHubControls", ["--deadline", "1"], 2),
        ("DeviceHubControls", ["--deadline", "1", "orientation", "bogus"], 2),
        ("DeviceHubControls", ["--deadline", "1", "orientation", "portrait"], 3),
        ("DeviceHubControls", ["--deadline", "1", "serve"], 3),
        ("HIDButtons", [], 2),
        ("HIDButtons", ["--deadline"], 2),
        ("HIDButtons", ["--deadline", "1", "button", "7", "4", "100"], 3),
        ("HIDButtons", ["--deadline", "1", "serve"], 3),
    ]

    @Test(arguments: earlyExits)
    func `should exit before acting when arguments are invalid or the start is late`(
        exit: (program: String, arguments: [String], status: Int32)
    ) async throws {
        let (status, output) = try await Self.launch(exit.program, exit.arguments)
        #expect(status == exit.status)
        #expect(output.isEmpty)
    }

    // Each program answers its own verbs only: a verb another one owns is a
    // usage error, not a silent success.
    @Test(arguments: [
        ("CoreMotionAngle", ["frontmost"]),
        ("CoreMotionAngle", ["angle", "90"]),
        ("AXPFrontmost", ["read-angle"]),
        ("AXPFrontmost", ["button", "7", "4", "100"]),
    ])
    func `should refuse a verb another program owns`(program: String, arguments: [String]) async throws {
        let (status, output) = try await Self.launch(program, arguments)
        #expect(status == 2)
        #expect(output.isEmpty)
    }

    /// The program built for macOS, run once with `arguments`.
    private static func launch(_ program: String, _ arguments: [String]) async throws -> (Int32, Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = try await Built.once.binary(of: program)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let status = try await exitStatus(of: process)
        return (status, output.fileHandleForReading.readDataToEndOfFile())
    }

    /// Compile `source` against `directories`' headers for macOS and require it to exit 0.
    private static func run(compiling source: String, including directories: [URL]) async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "InjectedProgramTest.m")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let binary = scratch.appending(path: "InjectedProgramTest")
        try await compile(directories.flatMap { ["-I", $0.path] } + [file.path], to: binary)
        let run = Process()
        run.executableURL = binary
        #expect(try await exitStatus(of: run) == 0)
    }

    private static func compile(_ inputs: [String], to binary: URL) async throws {
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation"] + inputs + ["-o", binary.path]
        try #require(try await exitStatus(of: compile) == 0)
    }

    /// Run `process` and await its exit without holding a thread: Swift
    /// Testing runs every suite on the cooperative pool, and a compile or a
    /// child blocked in `waitUntilExit()` holds a pool thread for seconds —
    /// enough of them, on a three-core CI runner, and no other suite's task
    /// gets one (#179).
    private static func exitStatus(of process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Each program under `Injected/` built once for the whole suite, however
    /// many cases launch it.
    private actor Built {
        static let once = Built()
        private let directory = FileManager.default.temporaryDirectory
            .appending(path: "baguette-injected-\(UUID().uuidString)")
        private var builds: [String: Task<URL, any Error>] = [:]

        func binary(of program: String) async throws -> URL {
            if let build = builds[program] { return try await build.value }
            let directory = directory
            let build = Task {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let files = try FileManager.default.contentsOfDirectory(atPath: sources(program).path)
                    .filter { $0.hasSuffix(".m") }
                    .map { sources(program).appending(path: $0).path }
                let binary = directory.appending(path: program)
                try await compile(["-I", InjectedProgramsGuestTests.shared.path] + files, to: binary)
                return binary
            }
            builds[program] = build
            return try await build.value
        }
    }
}
