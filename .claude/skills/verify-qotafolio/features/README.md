# QotaFolio verification map

This folder is the maintained source for verifying what a QotaFolio user can see and do. Read this index before you drive the app, then use the matching feature file as the recipe. Every command is `qfv`, from `../SKILL.md`, with `Q` set as that file shows.

## Baseline preconditions

- `"$Q" build` has run at the current source: `"$Q" doctor` shows `buildSource` equal to `currentSource`.
- `"$Q" launch <scenario>` has started the lane's own instance, and `"$Q" doctor` reports `"ok":true`.
- The installed app keeps running throughout. `doctor` shows its pid as `releasedAppPid`. Nothing in this map touches it.
- Each recipe names the scenario it needs. A recipe that needs a different scenario starts with `"$Q" stop` and a new `launch`.

## Driving conventions

- Drive through `"$Q" ax …` against the lane's pid. Selectors are stable accessibility identifiers wherever the app has one; `label=` and `nth=` are used only where it has none, and the recipe says so.
- The panel closes when anyone clicks elsewhere. Open it and use it in one `&&` chain: `"$Q" ax press id=qotafolio.statusItem && "$Q" ax wait id=qotafolio.panel 5 && …`.
- Treat every command as literal. Keep quoted selectors and values unchanged.
- Never press a control that leaves the Mac: `Open ChatGPT authorization page`, `Open browser`, `Copy code`, `Copy web address`, `Copy` (Terminal row). They open the owner's browser or overwrite his clipboard.
- End every run with `"$Q" clean`.

## Proof and skip reporting

- Capture the action and the result: a `snap` before the press and one after, plus a `shot` of the result.
- UI proof is an accessibility snapshot (`<name>.ax.json`) and a PNG of the window that holds the element.
- `qota` proof is the transcript `qfv qota` writes: command, stdout, stderr and exit code.
- A change made in one surface is proven in a second surface: the panel's order in the strip's sentence, a published scenario in `qota`.
- Name the feature file and the sub-feature ID with each artifact you report.
- A journey that cannot pass is reported as failing, with the command that showed it and the reason in that file's Gotchas. Never report a skipped entry point as verified through a different one.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph about the user-visible behaviour. It then has exactly four H2 sections, in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with qfv` (which starts with `Preconditions:` and pairs each user action with a command and an observable result), and `Gotchas`. Keep implementation detail out. Name only user paths, stable handles, required state, commands and observable proof.

## Features

| Feature | Covers |
|---|---|
| [Usage panel](./usage-panel.md) | Opening the panel, account cards and their states, card details, reorder, footer, reopen, Quit |
| [Menu-bar batteries](./menu-bar-strip.md) | One battery per account, the spoken sentence, session or week, hidden names |
| [qota command](./qota-cli.md) | `qota status`, `--json`, `--version`, errors, agreement with the panel |
| [Add an account](./add-account.md) | The naming step, Cancel, the ChatGPT device-code step, the recovery advisory |
| [Settings](./settings.md) | Opening Settings, the tabs, strip and appearance choices, account visibility, hidden names |

## Not covered by this map yet

- The panel shortcut ⌃⌥Q, notifications, Sparkle updates and Remove My Data. Each needs synthetic keyboard input, the notification centre, the network, or real data.
