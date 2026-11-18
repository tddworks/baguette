import Foundation
import Testing

/// `HingeControl`, the guest pose helper, compiled for macOS from
/// `Injected/HingeControl/Sources`: its native orientation values, the
/// `done <status>` reply per served command, and the `--deadline` after
/// which a helper that has not started refuses to act.
@Suite("HingeControl")
struct HingeControlTests {
    private static let sources = RepoRoot.url
        .appending(path: "Injected/HingeControl/Sources")

    @Test func `should follow the host protocol for orientation values, served replies and deadlines`() throws {
        try Self.run(compiling: """
        #import "HingeProtocol.h"
        #include <assert.h>
        #include <string.h>
        int main(void) {
          @autoreleasepool {
            for (NSString *name in @[@"portrait", @"pud", @"landscape-left", @"landscape-right"]) {
              __block int calls = 0;
              int result = dispatchHingeOrientation(name, ^BOOL(const char *value) {
                ++calls;
                assert([name isEqualToString:@(value)]);
                return YES;
              });
              assert(result == 0 && calls == 1);
              assert(dispatchHingeOrientation(name, ^BOOL(const char *value) { return NO; }) == 1);
            }
            for (NSString *name in @[@"", @"garbage", @"landscapeLeft", @"landscapeRight", @"portraitUpsideDown"]) {
              assert(dispatchHingeOrientation(name, ^BOOL(const char *value) {
                assert(0 && "invalid orientation dispatched"); return YES;
              }) == 2);
            }

            char script[] = "angle 10\\n\\n   \\nbogus\\norientation pud\\n";
            FILE *input = fmemopen(script, strlen(script), "r");
            char *text = NULL; size_t length = 0;
            FILE *output = open_memstream(&text, &length);
            NSMutableArray<NSString *> *seen = [NSMutableArray array];
            serveHingeCommands(input, output, ^int(NSArray<NSString *> *words) {
              [seen addObject:[words componentsJoinedByString:@" "]];
              if ([words.firstObject isEqualToString:@"bogus"]) return 2;
              if ([words.firstObject isEqualToString:@"orientation"]) return 1;
              return 0;
            });
            fclose(output);
            assert([seen isEqualToArray:(@[@"angle 10", @"bogus", @"orientation pud"])]);
            assert(strcmp(text, "done 0\\ndone 2\\ndone 1\\n") == 0);

            double deadline = 0;
            assert(parseHingeDeadline("1790615000.25", &deadline) && deadline == 1790615000.25);
            const char *invalid[] = {"", "soon", "12x", "inf", "nan"};
            for (int i = 0; i < 5; i++) assert(!parseHingeDeadline(invalid[i], &deadline));
            assert(hingeDeadlinePassed(1));
            assert(!hingeDeadlinePassed([NSDate date].timeIntervalSince1970 + 3600));
          }
          return 0;
        }
        """)
    }

    /// `button <page> <usage> <ms> [<page> <usage>]…` — trailing pairs are
    /// modifiers, down before the key and up after it in reverse, so a
    /// shifted letter or a Cmd chord types as on a hardware keyboard.
    @Test func `should hold a key's modifiers down around it and release them in reverse`() throws {
        try Self.run(compiling: """
        #import "HingeProtocol.h"
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

            assert(dispatchHingeButton(@[@"12", @"233", @"250"], key, hold) == 0);
            assert([events isEqualToArray:(@[@"down 12 233", @"hold 250", @"up 12 233"])]);

            [events removeAllObjects];
            assert(dispatchHingeButton(@[@"7", @"4", @"100", @"7", @"225", @"7", @"227"], key, hold) == 0);
            assert([events isEqualToArray:(@[
              @"down 7 225", @"down 7 227", @"down 7 4", @"hold 100", @"up 7 4", @"up 7 227", @"up 7 225"])]);

            // A refused key still releases everything it pressed.
            [events removeAllObjects];
            refuseDown = YES;
            assert(dispatchHingeButton(@[@"7", @"4", @"100", @"7", @"225"], key, hold) == 1);
            assert([events.lastObject isEqualToString:@"up 7 225"]);

            refuseDown = NO;
            [events removeAllObjects];
            for (NSArray *bad in @[@[], @[@"7", @"4"], @[@"7", @"4", @"100", @"7"], @[@"x", @"4", @"100"]]) {
              assert(dispatchHingeButton(bad, key, hold) == 2);
            }
            assert(events.count == 0);
          }
          return 0;
        }
        """)
    }

    /// `read-angle` and `watch-angle` print each valid sample the guest's
    /// CoreMotion reports as `angle <degrees>`; an invalid one is no reading.
    @Test func `should report each valid hinge sample to the host as an angle line`() throws {
        try Self.run(compiling: """
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
        """)
    }

    /// Every case here must exit before the helper creates HID services.
    @Test func `should exit before creating HID services when arguments are invalid or the start is late`() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let helper = scratch.appending(path: "HingeControl")
        // `frontmost` and the hinge readers live in their own translation units.
        try Self.compile(
            ["HingeControl.m", "Frontmost.m", "HingeAngle.m"].map { Self.sources.appending(path: $0).path }, to: helper)
        let cases: [([String], Int32)] = [
            ([], 2),
            (["orientation"], 2),
            (["orientation", "bogus"], 2),
            (["orientation", "landscapeLeft"], 2),
            (["orientation", "portrait", "extra"], 2),
            (["--deadline"], 2),
            (["--deadline", "soon", "orientation", "portrait"], 2),
            (["--deadline", "1"], 2),
            (["--deadline", "1", "orientation", "bogus"], 2),
            (["--deadline", "1", "orientation", "portrait"], 3),
            (["--deadline", "1", "serve"], 3),
        ]
        for (arguments, expected) in cases {
            let process = Process()
            let output = Pipe()
            process.executableURL = helper
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == expected, "\(arguments)")
            // A helper that does nothing never announces a pid to stop.
            #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "\(arguments)")
        }
    }

    /// Compile `source` against the helper headers for macOS and require it to exit 0.
    private static func run(compiling source: String) throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "HingeControlTest.m")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let binary = scratch.appending(path: "HingeControlTest")
        try compile(["-I", sources.path, file.path], to: binary)
        let run = Process()
        run.executableURL = binary
        try run.run()
        run.waitUntilExit()
        #expect(run.terminationStatus == 0)
    }

    private static func compile(_ inputs: [String], to binary: URL) throws {
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation"] + inputs + ["-o", binary.path]
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)
    }
}
