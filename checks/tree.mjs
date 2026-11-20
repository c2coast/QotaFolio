// What every rule reads, and how a rule reports.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

const root = new URL("../", import.meta.url);

// The files git would commit, tracked or new, by their path from the repository's root. No rule reads
// Sources/, the old tree, or .claude/, the sessions' own tooling.
export const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], { cwd: root })
  .toString()
  .split("\0")
  .filter((p) => p && !p.startsWith("Sources/") && !p.startsWith(".claude/") && !p.includes("/.claude/"))
  .filter((p) => existsSync(new URL(p, root)));

// A fixture or a recording: data copied from the world, which no person writes by hand.
export const DATA = /(^|\/)(fixtures|recordings)\//;

export const read =(path) => readFileSync(new URL(path, root), "utf8");

// The line, counted from 1, that holds the character at this index.
export const lineAt = (text, index) => text.slice(0, index).split("\n").length;

// Each breach is a test of its own, titled "file:line message", because the landing check prints only the
// titles of the tests that fail. A rule with no breach is one passing test that says how many files it read.
export function report(rule, count, breaches) {
  if (breaches.length === 0) test(`${rule} holds over ${count} files`, () => {});
  for (const breach of breaches) test(breach, () => assert.fail(breach));
}
