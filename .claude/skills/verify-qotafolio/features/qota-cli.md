# qota command

`qota` is the terminal command inside the app bundle (`Contents/MacOS/qota`). It reads the files the app writes into its App Group and prints every account's current usage: each window, the percentage used, the reset time and the app's note. `--json` prints the same as one document (schema 1). It only reads; it sends nothing over the network and never sees a token. Each build's `qota` reads only its own build's files.

## Sub-features

- `qota-status` prints one block per account and an `Updated` line.
- `qota-json` prints the same as JSON with `schemaVersion`, `generatedAt` and `accounts[]`.
- `qota-version` prints the version; `qota-help` prints the usage.
- `qota-errors` exits 64 on an unknown argument and 2 when the app has written nothing.
- `qota-agrees` shows the same accounts, percentages and reset times as the panel.
- `qota-follows-panel` shows a change the user made in the panel.

## How to get to it (user POV)

- Run `/Applications/QotaFolio.app/Contents/MacOS/qota status` in a terminal. Settings, General, Terminal shows this path with a Copy button.
- In this lab the same tool is the lane build's own copy, run through `"$Q" qota …`.

## Driving it with qfv

Preconditions:

- `"$Q" launch face`. The launch waits for `QF_PUBLISHED`, so the scenario's files are in the lane's App Group.

- **Status.** Run `"$Q" qota status`. Exit 0. Four blocks: `Personal (Claude · Max 20x)`, `Attilus (Claude · Pro)`, `Work (ChatGPT · Plus)`, `Spare (ChatGPT · Pro 20x)`. Rows read like `Session   38% used   resets 16:04 · in 2h 37m   ~43% left at reset`; the `Spare` session row ends `Spent`. The last line is `Updated <time> (<n> min ago)`.
- **JSON.** Run `"$Q" qota status --json`. Exit 0. `schemaVersion` is 1; `accounts` has four entries with `id`, `name`, `plan`, `provider`, `needsSignIn` and `windows[]` of `key`, `title`, `usedPercent`, `resetsAt`, `detail`.
- **Version and help.** Run `"$Q" qota --version`: `qota 1.0.0`. Run `"$Q" qota --help`: the usage text, exit 0.
- **Unknown argument.** Run `"$Q" qota frobnicate`. Exit 64, stderr starts `qota: unknown argument frobnicate`.
- **Nothing written.** Run `"$Q" clean`, then `"$Q" qota status`. Exit 2, stderr `qota: QotaFolio has not run yet, or has no accounts. Open QotaFolio and add one.` (`clean` removes the lane's files; the transcript still lands in the last run folder.)
- **Agrees with the panel.** Open the panel (`../usage-panel.md`, `panel-open`) and compare each card's percentages and reset times with the `qota status` rows. They match.
- **Follows the panel.** Move `Attilus` up in the panel (`panel-reorder`), then run `"$Q" qota status`. A user expects `Attilus` first. In the lab it stays second: this journey fails. See Gotchas.
- **Proof.** The `qota-N.txt` transcripts in the run folder, each with command, stdout, stderr and exit code.

## Gotchas

- `qota-follows-panel` fails in the lab, and the lab is the reason. The fixture writes the catalog once at launch and has no store behind the panel's reorder, rename or hide, so `qota` keeps the launch order. In the production app a reorder is written to the catalog. Proving that needs either a fixture catalog that writes through the real codec or a production run on a test account.
- Run the lane's `qota` only through `qfv qota`. The installed app's `qota` reads the operator's real files, which hold his account names; never run it for verification.
- `qota` refuses to run outside an app bundle (exit 64), so copying the binary elsewhere is not a test of it.
- Times are local and carry no date for resets within a day; the weekly reset carries a weekday. Assert percentages and names, and reset times only against the panel at the same moment.
