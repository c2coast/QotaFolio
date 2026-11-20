import { imports, swiftCode } from "./swift.mjs";
import { files, lineAt, read, report } from "./tree.mjs";
import { walls } from "./walls.mjs";

const wallOf = (path) =>
  walls.filter((wall) => path.startsWith(wall.folder)).sort((a, b) => b.folder.length - a.folder.length)[0];

for (const wall of walls) {
  const held = files.filter((p) => p.endsWith(".swift") && wallOf(p) === wall);
  const breaches = held.flatMap((p) => {
    const code = swiftCode(read(p));
    const refused = imports(code)
      .filter(({ module }) => !wall.imports.includes(module))
      .map(({ module, index }) => ({
        index,
        text: `imports ${module}. ${wall.folder} may import only ${wall.imports.join(", ")}. ${wall.importFix}`,
      }));
    for (const { call, pattern, fix } of wall.calls) {
      for (const m of code.matchAll(pattern)) refused.push({ index: m.index, text: `uses ${call}. ${fix}` });
    }
    return refused.sort((a, b) => a.index - b.index).map(({ index, text }) => `${p}:${lineAt(code, index)} ${text}`);
  });
  report(`the wall of ${wall.folder}`, held.length, breaches);
}
