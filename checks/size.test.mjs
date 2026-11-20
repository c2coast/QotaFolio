// A file an agent reads whole stays small enough to read whole.
import { DATA, files, read, report } from "./tree.mjs";

const BUDGET = 400;
const CODE = /\.(swift|m|h|c|ts|tsx|js|mjs|cjs|py|sh|css|html)$/;

const code = files.filter((p) => CODE.test(p) && !DATA.test(p));
report(
  `the budget of ${BUDGET} lines`,
  code.length,
  code.flatMap((p) => {
    const lines = read(p).replace(/\n$/, "").split("\n").length;
    if (lines <= BUDGET) return [];
    return [`${p}:${BUDGET + 1} has ${lines} lines, over the budget of ${BUDGET}. Split it into files that each do one job.`];
  }),
);
