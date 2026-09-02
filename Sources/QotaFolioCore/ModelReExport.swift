// `QotaFolioModel` split out of this target so that a widget extension and the `qota`
// command can decode this app's files without linking the policy, the words or the
// main-actor default that comes with them. Nothing about that split is any caller's
// business: every type still arrives with `import QotaFolioCore`.
@_exported import QotaFolioModel
