// The repository is public, and a fixture or a recording can be a copy of a real person's usage.
import { DATA, files, lineAt, read, report } from "./tree.mjs";

const PRIVATE = [
  {
    pattern: /[\w.%+-]+@(?!example\.(?:com|org|net)\b)[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}/g,
    text: "holds an email address. The repository is public. Write a made-up address at example.com.",
  },
  {
    pattern: /\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b/g,
    text: "holds an id in the shape of an account id. The repository is public. Write a made-up name such as account-a.",
  },
  {
    pattern: /\/(?:Users|home)\/(?!Shared\/)[\w.-]+/g,
    text: "holds a home path. The repository is public. Write the path from ~ instead.",
  },
];

const data = files.filter((p) => DATA.test(p));
report(
  "privacy in fixtures and recordings",
  data.length,
  data.flatMap((p) => {
    const text = read(p);
    return PRIVATE.flatMap(({ pattern, text: fix }) =>
      [...text.matchAll(pattern)].map((m) => `${p}:${lineAt(text, m.index)} ${fix}`),
    );
  }),
);
