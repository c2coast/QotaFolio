---
name: verify-qotafolio
description: Drive the real QotaFolio macOS menu-bar app and its `qota` command the way a user does, over invented fixture accounts, and capture proof (accessibility snapshots, PNGs, qota transcripts). Use before calling any QotaFolio change done, to check what the panel, the menu-bar batteries, Settings, the add-account flow or `qota` actually show, or whenever someone asks "does it work" about this app.
---

# Verify QotaFolio

QotaFolio is a menu-bar app. A user touches it in three places: the batteries in the menu bar, the panel that opens under them, and the Settings window. A fourth surface is `qota`, the command-line tool inside the app bundle. This skill builds a Debug copy of the app, starts it over invented accounts, drives it through the accessibility API, and keeps the evidence.

One command does all of it: `qfv`, in this skill's `bin/`. Every subcommand prints JSON. Start every session with:

```bash
Q="$(git rev-parse --show-toplevel)/.claude/skills/verify-qotafolio/bin/qfv"
"$Q" help
```

Read [features/README.md](features/README.md) next. It indexes the user-facing features and holds one recipe per feature.

## How the lab is isolated

- **One lane, one app identity.** `qfv` builds with `QOTAFOLIO_BUNDLE_ID=net.c2coast.QotaFolio.dev.verify`. That one setting gives the lab copy its own sandbox container, App Group, defaults, Keychain service and single-instance lease (`Sources/QotaFolioModel/Identity/AppIdentity.swift`). The installed app is `net.c2coast.QotaFolio`. A developer's own Debug build is `net.c2coast.QotaFolio.dev`. Neither is touched.
- **The lease is per identity.** It is a locked file inside the app's own sandbox container (`Sources/App/SingleInstanceLease.swift`). So the lab runs beside the installed app. A second start of the same lane does not run: it rings the first instance, which shows its panel, and exits. `qfv launch` refuses when the lane already runs.
- **Fixtures, not accounts.** `qfv launch <scenario>` sets `QOTAFOLIO_UI_SCENARIO`. The Debug build then builds `FixtureAppRuntime` (`Sources/App/Composition/Fixture/FixtureAppRuntime.swift`) instead of the production runtime: the real status item, panel, strip and Settings over invented accounts, with no Keychain and no network. An unknown scenario name falls through to the production runtime, so `qfv launch` accepts only names it reads from `Sources/UIFixtures/FixtureUIScenarios.swift`.
- **Parallel lanes.** Set `QFV_LANE=<lower-case letters and digits>` on every `qfv` call to get a second identity, build folder and evidence stream. Each lane needs its own build (about 30 s cold).
- **What stays shared with the operator.** The screen, the menu bar and the global shortcut. While a lab instance runs it registers the panel shortcut ⌃⌥Q for itself (`QF_HOTKEY register … status=0` in its log), the same keys the installed app uses. Its panel appears on the operator's screen when opened. Keep runs short and always end with `qfv clean`.

## Launch

```bash
"$Q" build            # xcodegen, then a Debug build of the lane through axbuild; ~30 s cold, ~5 s warm
"$Q" launch face      # starts the lab over the `face` scenario; prints pid, evidence folder, the strip's sentence
```

- Scenarios: `face` (four accounts with a week of history, times anchored to now), `states` (stale, waiting, needs sign-in, setup issue), `new-account`, `mixed` (five accounts, fixed date), `device-code`, `recovery`, `empty`, `first-run`.
- Extra `QOTAFOLIO_UI_*=value` arguments pass straight to the app, for example `"$Q" launch face QOTAFOLIO_UI_STRIP=week`. The header of `FixtureAppRuntime.swift` documents every one.
- `qfv launch` always adds `QOTAFOLIO_UI_PUBLISH_FILES=1`, so the scenario is written into the lane's App Group through the app's own codecs and `qota` has something to read.
- **Ready means usable.** `launch` returns only after the status item exists in the accessibility tree with its spoken sentence, and after the app has printed `QF_PUBLISHED`. It fails with the log path if the app exits or the item does not appear within 20 s.
- `build` prints `{"ok":…,"exit":…,"source":"<HEAD>-<hash of uncommitted app changes>"}`. On failure, read the axbuild report it names, per the `axiom-build` skill.

## Doctor

```bash
"$Q" doctor
```

Read-only. Run it first, and again whenever anything looks off. `"ok":true` with an empty `issues` means the lane is worth driving. It reports:

- `built`, `buildSource` against `currentSource`: a mismatch means the app under test is not the code in front of you. Run `qfv build`.
- `pid`, `scenario`, `statusItem` (the strip's spoken sentence), `panelOpen`: whether the lane's own instance is up and answering.
- `permissions`: `accessibility` and `screenRecording` for the terminal app that runs `qfv` (macOS grants both to the app, not to the shell). Without Accessibility, `qfv ax`, `snap` and `shot` cannot read or press anything. Without Screen Recording, `shot` captures only the wallpaper. `doctor` reads both without asking for them. When one is missing, report it to the operator as a finding: which permission, for which terminal app, and what it unlocks. Never click through a permission dialog.
- `releasedAppPid`: the installed app, observed and never touched.
- `otherDebugInstances`: other QotaFolio builds on screen. They do not affect window shots or the tree, only `--frame` shots that cover the same pixels.

## Drive

The drive is the accessibility API, aimed at the lane's pid. `qfv ax press` performs AXPress, the action VoiceOver performs. It moves no pointer, posts no keyboard event and needs no window focus. The app's views carry stable identifiers (`Sources/QotaFolioCore/Policy/Accessibility/AXIdentifiers.swift`, `SettingsAXIdentifiers` in `Sources/QotaFolioKit/Settings/SettingsAddFlowSurface.swift`), so selectors name what a user sees, not coordinates.

```bash
"$Q" ax press id=qotafolio.statusItem          # the user's click on the batteries
"$Q" ax wait  id=qotafolio.panel 5             # wait for the panel; prints waitedMs and its frame
"$Q" ax tree                                   # the whole tree: roles, ids, labels, values, frames
"$Q" ax find  'role=AXMenuItem&label=Quit'     # one element
"$Q" ax press 'role=AXRadioButton&label=Accounts'   # a Settings tab
"$Q" ax press 'role=AXCheckBox&label=Show account&nth=2'   # the second match
"$Q" ax set   id=qotafolio.auth.nameField "Lab account"    # write a field's value
"$Q" reopen                                    # start the app again, as Finder or Spotlight would
```

- Selectors: `id=` exact AXIdentifier, `role=` exact AXRole, `label=` case-insensitive substring of title, label, value or help, `nth=` the k-th match in tree order. Join terms with `&` and quote the whole selector.
- Account ids in fixtures are fixed: `face` and `states` use `00000000-0000-4000-8000-00000000000N`, `mixed` uses `00000000-0000-0000-0000-00000000000N`, where N is the card's place in the scenario.
- **The panel is transient.** It closes when the operator clicks anywhere else, exactly as it does for a user. Chain the press that opens it and the steps that use it in one shell command with `&&`. If a step reports "no element matches", reopen the panel and repeat the chain.
- A menu opened with AXPress (the footer's More, a card's More) stays open until one of its items is pressed or the panel closes.
- Settings is an ordinary window. It opens beside the operator's windows without taking keyboard focus from them.
- The lab's own stdout carries `QF_` lines: `QF_PUBLISHED <dir>`, `QF_HOTKEY …`, `QF_PANEL_RESIZE …`. Read them with `"$Q" log`.

## Evidence

Each `qfv launch` creates a run folder `<repo>/.artifacts/verify/<date>-<time>-<lane>-<scenario>/` and points `<repo>/.artifacts/verify/latest` at it. `.artifacts/` is ignored by git. Cleanup never deletes it.

```bash
"$Q" snap panel-open                          # <run>/panel-open.ax.json, the accessibility tree
"$Q" shot panel-open id=qotafolio.panel        # <run>/panel-open.png, the window that holds the element
"$Q" shot strip id=qotafolio.statusItem --frame   # <run>/strip.png, exactly the element's frame on screen
"$Q" qota status --json                        # <run>/qota-N.txt: command, stdout, stderr, exit code
```

The run folder also holds `launch.env` (the exact environment), `manifest.jsonl` (one line per artifact with the command that made it) and, after `qfv stop`, `app.log`.

Proof standards:

- Drive the user's path. Open the panel by pressing the status item, not with `QOTAFOLIO_UI_OPEN_PANEL`. Quit with the panel's Quit, which `qfv quit` does.
- Capture the action and its result: a snapshot or shot before the press and after it, not only the final screen.
- Prove side effects on a second surface. A reorder in the panel shows in the strip's spoken order. A published scenario shows in `qota`.
- The accessibility snapshot is the primary proof: it is text, it is exact, and it holds what VoiceOver reads. The PNG is for what a sighted user sees.
- A window shot (`shot` without `--frame`) shows only the lab's window, so nothing private from the operator's screen gets in. It draws the panel's Liquid Glass as a flat grey sheet, because the glass samples the screen behind the window. Content and layout are exact; the glass is not. For a picture of the glass, use `--frame` on the panel, or the lab's own photographer knobs (`QOTAFOLIO_UI_APPEARANCE=light|dark` puts a wallpaper backdrop over the whole screen for the run). A `--frame` shot captures every pixel in that rectangle, including other windows.
- The status item has no window of its own on macOS 27: the system draws menu extras. Shoot it with `--frame`.
- A fixture proves the app's own surfaces and logic over invented data. It does not prove anything about the provider's network responses or the Keychain. Those are outside this lab.

## Cleanup

```bash
"$Q" clean
```

`clean` quits the lane's instance through its own Quit, removes the published files from the lane's App Group, unregisters the lane's build from LaunchServices and PlugInKit, and deletes the lane's run state. It prints the evidence folder, which stays, and the installed app's pid, which is still running.

- `qfv stop` only ends the instance. It tries the user's Quit first (cancelling an open add flow first). When Quit cannot be reached, it sends SIGTERM, then SIGKILL, to the recorded pid and to nothing else. `stoppedBy` says which.
- A Quit runs the app's own termination, which deletes the fixture's throwaway defaults domain. A signal skips that, so one small preferences file may stay inside the lane's own container. It is never read again.
- Run `clean` after every failed attempt too, so no instance holds the lane, the shortcut or a place in the menu bar.
- The build in `.build/verify/<lane>/` stays for the next run. Delete that folder to start cold.

## Helpers

- `bin/qfv` (bash, executable): every subcommand above. `"$Q" help` lists them with their arguments.
- `bin/qfv-ax.swift` (Swift, executable): the accessibility reader and presser. `qfv` compiles it into `.build/verify/tools/qfv-ax` when the source is newer, and passes the lane's pid. Call it through `qfv ax …`. Run directly it takes the pid first: `.build/verify/tools/qfv-ax find <pid> id=qotafolio.panel`.
- The build log and report: `.build/verify/<lane>/build.json` (axbuild's JSON) and the run folder it names.

## Not in the repo yet

Two surfaces of the planned product do not exist here today: the Claude Code plugin that shows usage, and the Agent Dashboard (a web page in a floating window over iTerm2). Do not look for them. Each joins `features/` when it lands.
