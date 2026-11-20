// Swift source as a rule reads it: the code alone, and the modules it imports.

const OPENS_STRING = /(#*)("""|")/y;

// The source with every comment and the text of every string literal turned to spaces, so a rule matches
// only code. Line breaks stay, so a line number still points at the source. The code inside a string's
// \( ) stays, because it runs.
export function swiftCode(src) {
  let i = 0;
  let out = "";
  const keep = (n) => {
    out += src.slice(i, i + n);
    i += n;
  };
  const blank = (n) => {
    out += src.slice(i, i + n).replace(/[^\n]/g, " ");
    i += n;
  };

  const lineComment = () => {
    const end = src.indexOf("\n", i);
    blank((end < 0 ? src.length : end) - i);
  };

  // Swift's block comments nest.
  const blockComment = () => {
    let depth = 0;
    do {
      if (src.startsWith("/*", i)) depth++;
      if (src.startsWith("*/", i)) depth--;
      blank(src.startsWith("/*", i) || src.startsWith("*/", i) ? 2 : 1);
    } while (depth > 0 && i < src.length);
  };

  const string = (hashes, triple) => {
    const close = (triple ? '"""' : '"') + "#".repeat(hashes);
    const escape = "\\" + "#".repeat(hashes);
    while (i < src.length) {
      if (src.startsWith(close, i)) return keep(close.length);
      if (!triple && src[i] === "\n") return;
      if (!src.startsWith(escape, i)) blank(1);
      else if (src[i + escape.length] === "(") {
        keep(escape.length + 1);
        code(true);
        keep(1);
      } else blank(escape.length + 1);
    }
  };

  // Reads code to the end of the source, or, inside an interpolation, to the ) that closes it.
  const code = (interpolation) => {
    let depth = 0;
    while (i < src.length) {
      OPENS_STRING.lastIndex = i;
      const opens = (src[i] === '"' || src[i] === "#") && OPENS_STRING.exec(src);
      if (src.startsWith("//", i)) lineComment();
      else if (src.startsWith("/*", i)) blockComment();
      else if (opens) {
        keep(opens[0].length);
        string(opens[1].length, opens[2] === '"""');
      } else if (interpolation && src[i] === ")" && depth === 0) return;
      else {
        if (src[i] === "(") depth++;
        if (src[i] === ")") depth--;
        keep(1);
      }
    }
  };

  code(false);
  return out;
}

const IMPORT =
  /(?:^|;)[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func|actor|macro)\s+)?(\w+)/gm;

// Each module the code imports, with the index of its name in the code. Takes code from swiftCode.
export const imports = (code) =>
  [...code.matchAll(IMPORT)].map((m) => ({ module: m[1], index: m.index + m[0].length - m[1].length }));
