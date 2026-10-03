import Foundation
import Testing

/// `HingeControl`, the guest pose helper, compiled for macOS from
/// `Injected/HingeControl/Sources`: its native orientation values, the
/// `done <status>` reply per served command, and the `--deadline` after
/// which a helper that has not started refuses to act.
@Suite("HingeControl")
struct HingeControlTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Injected/HingeControl/Sources")

    @Test func `orientation values, served replies and deadlines follow the host protocol`() throws {
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

    /// Every case here must exit before the helper creates HID services.
    @Test func `invalid arguments and late starts exit before creating HID services`() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let helper = scratch.appending(path: "HingeControl")
        // `frontmost` lives in its own translation unit; the helper links both.
        try Self.compile(
            ["HingeControl.m", "Frontmost.m"].map { Self.sources.appending(path: $0).path }, to: helper)
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
