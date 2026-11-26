// Version 1.0.0 is build 100. Its updater refuses an update whose build number is not a whole number
// (ProductionSparkleUpdateDelegate), and Sparkle offers only a build above the one running. The build number
// is CURRENT_PROJECT_VERSION, which becomes CFBundleVersion and the appcast's sparkle:version.
import { lineAt, read, report } from "./tree.mjs";

const SPEC = "project.yml";
const SHIPPED = 100;

const spec = read(SPEC);
const builds = [...spec.matchAll(/CURRENT_PROJECT_VERSION:\s*"?([^"\s]*)"?/g)];
report(`a build number above ${SHIPPED}`, 1, [
  ...(builds.length ? [] : [`${SPEC}:1 sets no CURRENT_PROJECT_VERSION. Set it to a whole number above ${SHIPPED}.`]),
  ...builds
    .filter(([, build]) => !/^[1-9]\d*$/.test(build) || Number(build) <= SHIPPED)
    .map((m) => `${SPEC}:${lineAt(spec, m.index)} sets build ${m[1]}. Version 1.0.0 updates only to a whole number above ${SHIPPED}.`),
]);
