// A test runs at every landing, on the owner's Mac, while he works. So it puts nothing on his screen and
// leaves his login Keychain alone.
import { swiftCode } from "./swift.mjs";
import { files, lineAt, read, report } from "./tree.mjs";

const TEST_SOURCE = /(^|\/)[Tt]ests\/.*\.swift$|Tests\.swift$/;

const REFUSED = [
  {
    pattern: /\b(NSWindow\w*|NSPanel|NSStatusBar|NSStatusItem|NSAlert|NSApp|NSApplication|NSWorkspace|XCUIApplication)\b/g,
    fix: "A test puts nothing on screen. Test the value the view is drawn from.",
  },
  {
    pattern: /\b(SecItem\w+|SecKeychain\w*)\b/g,
    fix: "A test leaves the login Keychain alone. Hand the code a store that keeps its items in memory.",
  },
];

const sources = files.filter((p) => TEST_SOURCE.test(p));
report(
  "hostless tests",
  sources.length,
  sources.flatMap((p) => {
    const code = swiftCode(read(p));
    return REFUSED.flatMap(({ pattern, fix }) =>
      [...code.matchAll(pattern)].map((m) => `${p}:${lineAt(code, m.index)} uses ${m[1]}. ${fix}`),
    );
  }),
);
