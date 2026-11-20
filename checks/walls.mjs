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
    folder: "app/views/panel/graph/",
    imports: ["Foundation", "Kit", "SwiftUI"],
    importFix: "The graph draws a week picture it is handed. What it needs from the Mac comes in as plain values.",
    calls: pure("The graph"),
  },
  {
    folder: "app/views/panel/graph/tests/",
    imports: ["Accessibility", "Foundation", "Graph", "Kit", "SwiftUI", "Testing"],
    importFix: "The graph's tests read its geometry, what it says aloud and the image it draws. Nothing else.",
    calls: [],
  },
  {
    folder: "app/lease/",
    imports: ["Darwin", "Dispatch", "Foundation"],
    importFix: "The lease is a lock on a file it is handed. The app derives the file from its identity and passes it in.",
    calls: [
      { call: "homeDirectory", pattern: /\bhomeDirectory\w*|\bNSHomeDirectory\b/g, fix: "The lease takes its file. The app finds the home folder." },
    ],
  },
  {
    folder: "app/lease/tests/",
    imports: ["Darwin", "Foundation", "Testing"],
    importFix: "The lease's tests take a real lock in a temporary folder, and need nothing else.",
    calls: [
      { call: "homeDirectory", pattern: /\bhomeDirectory\w*|\bNSHomeDirectory\b/g, fix: "A test of the lease works in a temporary folder, never in the home folder." },
    ],
  },
  {
    folder: "app/recorder/legacy/",
    imports: ["Foundation", "Kit"],
    importFix: "The reader of 1.0.0's history turns the file's bytes into kit's values, and needs nothing else.",
    calls: pure("The reader of 1.0.0's history"),
  },
];
