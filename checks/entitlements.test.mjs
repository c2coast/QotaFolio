// The app runs outside the App Sandbox. A sandbox comes back through one of two doors: a key in an
// entitlements file, or the build setting that adds the key when the app is signed. The landing check builds
// unsigned, so this rule reads both at their source. The release lane reads the signed app.
import { files, lineAt, read, report } from "./tree.mjs";

const SPEC = "project.yml";

const KEYS = [
  {
    pattern: /<key>com\.apple\.security\.app-sandbox<\/key>/g,
    text: "puts the app in the App Sandbox. QotaFolio runs outside it: delete the key.",
  },
  {
    pattern: /<key>com\.apple\.security\.temporary-exception\.[^<]*<\/key>/g,
    text: "asks for a sandbox exception, which means nothing outside the sandbox: delete the key.",
  },
];

const entitlements = files.filter((p) => p.endsWith(".entitlements"));
const spec = read(SPEC);
const at = (m) => `${SPEC}:${lineAt(spec, m.index)}`;

report("no sandbox and no exception entitlement", entitlements.length + 1, [
  ...entitlements.flatMap((p) => {
    const text = read(p);
    return KEYS.flatMap(({ pattern, text: fix }) =>
      [...text.matchAll(pattern)].map((m) => `${p}:${lineAt(text, m.index)} ${fix}`),
    );
  }),
  ...[...spec.matchAll(/ENABLE_APP_SANDBOX:\s*"?YES"?/g)].map(
    (m) => `${at(m)} switches the App Sandbox on, and signing adds it to the app. Delete the setting.`,
  ),
  ...[...spec.matchAll(/CODE_SIGN_ENTITLEMENTS:\s*"?([^"\s]+)"?/g)]
    .filter((m) => !entitlements.includes(m[1]))
    .map((m) => `${at(m)} signs with ${m[1]}, which no rule reads. Keep it in the new tree, as app/main/QotaFolio.entitlements is.`),
]);
