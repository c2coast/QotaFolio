// The walls of the new tree. A Swift file obeys the wall of the deepest folder that holds it. It may import
// only the modules its wall lists, and it may not make the calls its wall names. Each refusal names its fix.

// What pure code may not call: it takes the world as values.
const pure = (who) => [
  { call: "Date()", pattern: /\bDate\s*\(\s*\)|\bDate\.now\b/g, fix: `${who} is pure. Take now as a parameter.` },
  { call: "Process", pattern: /\bProcess\b/g, fix: `${who} is pure. The app runs programs and hands it the result.` },
  { call: "FileManager", pattern: /\bFileManager\b/g, fix: `${who} is pure. The app reads files and hands it the values.` },
  { call: "URLSession", pattern: /\bURLSession\w*/g, fix: `${who} is pure. The app asks servers and hands it the answer.` },
];

export const walls = [
  {
    folder: "kit/",
    imports: ["Foundation"],
    importFix: "kit is pure. Code that needs another module belongs in the app, which hands kit plain values.",
    calls: pure("kit"),
  },
  {
    folder: "kit/tests/",
    imports: ["Foundation", "Kit", "Testing"],
    importFix: "kit's tests use Kit and Swift Testing. A test of the app's code goes beside that code.",
    calls: [],
  },
  {
    folder: "app/recorder/legacy/",
    imports: ["Foundation", "Kit"],
    importFix: "The reader of 1.0.0's history turns the file's bytes into kit's values, and needs nothing else.",
    calls: pure("The reader of 1.0.0's history"),
  },
];
