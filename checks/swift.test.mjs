// The rules read Swift through swiftCode and imports. A mistake here hides a breach without a sound, so the
// reader is held to cases worked by hand.
import assert from "node:assert/strict";
import { test } from "node:test";
import { imports, swiftCode } from "./swift.mjs";

const kept = (src, word) => swiftCode(src).indexOf(word) === src.indexOf(word) && src.includes(word);
const gone = (src, word) => !swiftCode(src).includes(word);

test("swiftCode drops a word in a line comment and keeps the next line", () => {
  const src = "// Process the readings\nlet p = Process()";
  assert.ok(kept(src, "Process()"));
  assert.equal(swiftCode(src).indexOf("Process"), src.indexOf("Process()"));
});

test("swiftCode drops nested block comments and keeps the code after them in place", () => {
  const src = "/* outer /* inner */ Process */ let f = FileManager.default";
  assert.ok(gone(src, "Process"));
  assert.ok(kept(src, "FileManager"));
});

test("swiftCode drops the text of a string, its escaped quotes included", () => {
  assert.ok(gone('let s = "Date() and \\"Process\\" in text"', "Date"));
  assert.ok(gone('let s = "Date() and \\"Process\\" in text"', "Process"));
});

test("swiftCode keeps the code inside an interpolation", () => {
  assert.ok(kept('let s = "now: \\(Date().description)" + "Process"', "Date()"));
  assert.ok(gone('let s = "now: \\(Date().description)" + "Process"', "Process"));
});

test("swiftCode reads a raw string to its own closing quote", () => {
  const src = 'let s = #"no \\(Date()) and "Process" here"#; let u = URLSession.shared';
  assert.ok(gone(src, "Date"));
  assert.ok(gone(src, "Process"));
  assert.ok(kept(src, "URLSession"));
});

test("swiftCode drops a multi-line string and keeps every line break", () => {
  const src = 'let s = """\n  Process\n  """\nlet f = FileManager.default';
  assert.ok(gone(src, "Process"));
  assert.ok(kept(src, "FileManager"));
  assert.equal(swiftCode(src).split("\n").length, 4);
});

test("swiftCode ends a one-line string at its line, so a quote in a regex literal hides one line at most", () => {
  assert.ok(kept('let quote = /"/\nlet p = Process()', "Process"));
});

test("imports finds each module, however the import is written, and nothing in a comment or a string", () => {
  const src = [
    "import Foundation",
    "@testable import Kit",
    "import struct SwiftUI.Color; import AppKit",
    "// import GRDB",
    'let s = "import Sparkle"',
    "@_spi(Charts) public import",
    "  Charts",
  ].join("\n");
  const code = swiftCode(src);
  const found = imports(code).map(({ module, index }) => `${module}:${code.slice(0, index).split("\n").length}`);
  assert.deepEqual(found, ["Foundation:1", "Kit:2", "SwiftUI:3", "AppKit:3", "Charts:7"]);
});
