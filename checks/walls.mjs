// The walls of the new tree. A Swift file obeys the wall of the deepest folder that holds it. It may import
// only the modules its wall lists, and it may not make the calls its wall names. Each refusal names its fix.
export const walls = [
  {
    folder: "kit/",
    imports: ["Foundation"],
    importFix: "kit is pure. Code that needs another module belongs in the app, which hands kit plain values.",
    calls: [
      { call: "Date()", pattern: /\bDate\s*\(\s*\)|\bDate\.now\b/g, fix: "kit is pure. Take now as a parameter." },
      { call: "Process", pattern: /\bProcess\b/g, fix: "kit is pure. The app runs programs and hands kit the result." },
      { call: "FileManager", pattern: /\bFileManager\b/g, fix: "kit is pure. The app reads files and hands kit the values." },
      { call: "URLSession", pattern: /\bURLSession\w*/g, fix: "kit is pure. The app asks servers and hands kit the answer." },
    ],
  },
];
