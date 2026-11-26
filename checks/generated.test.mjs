// A generated file is committed, and it holds exactly what tools/gen makes of its source. A change made
// in the generated file alone is lost at the next run, and a change made in the source alone never
// reaches the build.
import { generated } from "../tools/gen.mjs";
import { files, read, report } from "./tree.mjs";

report(
  "the generated files",
  generated.length,
  generated.flatMap(({ path, source, make }) => {
    let text;
    try {
      text = make();
    } catch (error) {
      return [`${error.message} Change ${source}, then run tools/gen.`];
    }
    if (!files.includes(path)) return [`${path}:1 is missing. Run tools/gen.`];
    const held = read(path).split("\n");
    const wanted = text.split("\n");
    const line = wanted.findIndex((l, i) => held[i] !== l);
    if (line < 0 && held.length === wanted.length) return [];
    const at = (line < 0 ? Math.min(held.length, wanted.length) : line) + 1;
    return [`${path}:${at} differs from what tools/gen makes of ${source}. Change ${source}, never the generated file, then run tools/gen.`];
  }),
);
