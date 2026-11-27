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
    folder: "app/views/panel/",
    imports: ["Graph", "Kit", "SwiftUI"],
    importFix: "The panel's views lay out Kit's value in the design values. The old tree's card hands them the value and the words.",
    calls: pure("The panel's views"),
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
    folder: "app/main/tests/",
    imports: ["Foundation", "QotaFolioModel", "Testing"],
    importFix: "The tests of the app's identity read its names through QotaFolioModel, and need nothing else.",
    calls: [
      { call: "AppIdentity.current", pattern: /\bAppIdentity\.current\b/g, fix: "A test names the identity it reads, the release's or a development build's, never the running one." },
      { call: "homeDirectory", pattern: /\bhomeDirectory\w*|\bNSHomeDirectory\b/g, fix: "A test hands the identity a home folder of its own, never the real one." },
    ],
  },
  {
    folder: "app/settings/legacy/",
    imports: ["Foundation"],
    importFix: "The carry reads one file and writes one domain it is handed, with Foundation alone.",
    calls: [
      ...pure("The carry").filter(({ call }) => call !== "FileManager"),
      { call: "UserDefaults.standard", pattern: /\bUserDefaults\.standard\b|\.standard\b/g, fix: "The carry writes the defaults it is handed. The app hands it UserDefaults.standard." },
      { call: "homeDirectory", pattern: /\bhomeDirectory\w*|\bNSHomeDirectory\b/g, fix: "The carry takes the file it reads. The app derives it from its identity." },
    ],
  },
  {
    folder: "app/settings/legacy/tests/",
    imports: ["Foundation", "Testing"],
    importFix: "The carry's tests write a file in a temporary folder and read the domain back, and need nothing else.",
    calls: [
      { call: "UserDefaults", pattern: /\bUserDefaults\b/g, fix: "A test of the carry never opens a real defaults domain. Run the carry on dictionaries." },
      { call: "homeDirectory", pattern: /\bhomeDirectory\w*|\bNSHomeDirectory\b/g, fix: "A test of the carry works in a temporary folder, never in the home folder." },
    ],
  },
  {
    folder: "app/settings/hidden/",
    imports: ["Foundation", "QotaFolioModel"],
    importFix: "The hidden accounts are a key, a list of ids and a filter, which the app and qota both compile. They need Foundation and QotaFolioModel alone.",
    calls: [
      ...pure("The list of hidden accounts"),
      { call: "a defaults domain", pattern: /\bUserDefaults\s*\(|\bUserDefaults\.standard\b|\.standard\b/g, fix: "The list reads and writes the defaults it is handed. The app hands it its own, and qota opens the app's domain by name." },
    ],
  },
  {
    folder: "app/settings/hidden/tests/",
    imports: ["Foundation", "QotaFolioModel", "Testing"],
    importFix: "The tests of the hidden accounts run the list and the filter on values, and need nothing else.",
    calls: [
      { call: "UserDefaults", pattern: /\bUserDefaults\b/g, fix: "A test of the hidden accounts never opens a real defaults domain. Run the list and the filter on values." },
    ],
  },
  {
    folder: "app/recorder/legacy/",
    imports: ["Foundation", "Kit"],
    importFix: "The reader of 1.0.0's history turns the file's bytes into kit's values, and needs nothing else.",
    calls: pure("The reader of 1.0.0's history"),
  },
];
