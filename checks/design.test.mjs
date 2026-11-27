// The design values have one home, design/tokens.json. Outside the file tools/gen writes from it, the
// new tree's code writes no font size and no colour as numbers: it reads Kit's Tokens. A test may write
// the values it expects by hand.
import { generated } from "../tools/gen.mjs";
import { swiftCode } from "./swift.mjs";
import { files, lineAt, read, report } from "./tree.mjs";

const FIX = "Read it from Tokens, and add it to design/tokens.json with its why if it is new, then run tools/gen.";

const refused = [
  {
    what: "a font size as a number",
    pattern: /\b(?:system|custom|\w*[Ff]ont)\s*\([^()]*?\b(?:size|ofSize|fixedSize)\s*:\s*[-+]?\.?\d/g,
  },
  {
    what: "a colour as numbers",
    pattern: /\b(?:Color|NSColor|CGColor|UIColor|RGBA)\s*\(\s*(?:\.\w+\s*,\s*)?(?:\w+\s*:\s*)?[-+]?\.?\d/g,
  },
  { what: "a colour as a hex number", pattern: /\b0x[0-9A-Fa-f]{6}\b/g },
  { what: "a colour as a weight of black, white or ink", pattern: /\b(?:black|white|primary|gray)\s*\.opacity\s*\(\s*[-+]?\.?\d/g },
];

const code = files.filter(
  (p) => p.endsWith(".swift") && !/(^|\/)tests\//.test(p) && !generated.some(({ path }) => path === p),
);
report(
  "the design values",
  code.length,
  code.flatMap((p) => {
    const swift = swiftCode(read(p));
    return refused
      .flatMap(({ what, pattern }) => [...swift.matchAll(pattern)].map((m) => ({ index: m.index, what })))
      .sort((a, b) => a.index - b.index)
      .map(({ index, what }) => `${p}:${lineAt(swift, index)} writes ${what}. ${FIX}`);
  }),
);
