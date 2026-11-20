# Add an account

A user adds an account from the panel: he names it, picks Anthropic or ChatGPT, and continues to the provider's sign-in. ChatGPT signs in with a device code shown in the panel; Anthropic signs in through the browser. When the account list is missing but saved sign-ins remain, the panel says so instead of showing an empty fleet. In the lab every sign-in stops before the provider: nothing opens a browser or calls the network.

## Sub-features

- `add-open-empty` opens the naming step from an empty panel.
- `add-open-footer` opens the naming step from the footer of a panel that has accounts.
- `add-cancel` leaves the naming step and returns to the panel.
- `add-continue` takes a name and a provider to the sign-in step.
- `add-device-code-live` shows a live ChatGPT device code with its countdown.
- `add-device-code-expired` shows an expired code with `Get a new code`.
- `add-recovery` explains a missing account list with saved sign-ins.
- `add-first-run` opens straight on the naming step.

## How to get to it (user POV)

- With no account: click the batteries, then `Add your first account…`.
- With accounts: click the batteries, then the footer's `+` (`Add Account…`).
- Settings, Accounts, `Add Account…`.

## Driving it with qfv

Preconditions:

- `"$Q" launch empty` unless a step names another scenario. `"$Q" doctor` reports `"ok":true`.

- **Open from an empty panel.** Run `"$Q" ax press id=qotafolio.statusItem && "$Q" ax wait id=qotafolio.footer.addAccount 5 && "$Q" snap add-before && "$Q" ax press id=qotafolio.footer.addAccount && "$Q" ax wait id=qotafolio.auth.nameField 5 && "$Q" snap add-naming`. Before: a static text `No accounts yet, …` and the button `Add your first account…`. After: heading `Add an account` (`qotafolio.auth.add.heading`), the text field `qotafolio.auth.nameField`, the radio group `qotafolio.auth.provider` with `Anthropic` selected, and the buttons `qotafolio.auth.cancel` and `qotafolio.auth.continue`.
- **Open from the footer.** With `face`, the same chain opens the same step; the footer button's label is `Add Account…`.
- **Cancel.** In the naming step run `"$Q" ax press id=qotafolio.auth.cancel && sleep 0.5 && "$Q" ax find id=qotafolio.footer.addAccount`. The naming step is gone and the empty panel is back.
- **Continue.** In the naming step run `"$Q" ax set id=qotafolio.auth.nameField "Lab account" && "$Q" ax press id=qotafolio.auth.continue && sleep 1 && "$Q" snap add-continue`. A user expects the Anthropic sign-in step (`qotafolio.auth.anthropic.status`). In the lab the field shows `Lab account` and the step stays on naming: this journey fails. See Gotchas.
- **Expired device code.** `"$Q" stop && "$Q" launch device-code`, then open the panel. Heading `Sign in to ChatGPT`, static texts `Code expired` and `https://auth.openai.com/codex/device`, and the button `qotafolio.auth.chatgpt.getNewCode` labelled `Get a new code`.
- **Live device code.** A user who just started the flow sees the code `ABCD-EFGH` (`qotafolio.auth.chatgpt.code`) and a countdown. The lab cannot show it: this journey fails. See Gotchas.
- **Recovery.** `"$Q" stop && "$Q" launch recovery`, then open the panel. An element `qotafolio.catalog.recoveryAdvisory` reads `QotaFolio's account list is missing, but 2 saved sign-ins are still in your Mac's Keychain. Nothing has been d…`, above `Add your first account…`.
- **First run.** `"$Q" stop && "$Q" launch first-run`, then open the panel. It opens on the naming step.
- **Proof.** `add-before.ax.json` and `add-naming.ax.json`, plus a `shot` of `id=qotafolio.panel` at each step.

## Gotchas

- `add-continue` fails through this harness. `qfv ax set` writes the text field's accessibility value, and the field shows it, but the step does not advance. The Continue button is disabled while the trimmed name is empty (`NameProviderStep.swift`), so the likely cause is that an accessibility value write does not reach SwiftUI's binding. Typing would, and this lab posts no keyboard events. Not yet determined whether VoiceOver typing has the same problem.
- `add-device-code-live` fails in the lab because the `device-code` scenario is pinned to a fixed date, 1 September 2026, with a 15-minute expiry. Every launch after that shows the expired state. A scenario anchored to the launch time, as `face` is, would show the live code.
- Do not press `Open ChatGPT authorization page`, `Copy web address`, `Copy code` or the Anthropic `Open browser` button. They open the owner's browser or replace his clipboard.
- The panel closes when the owner clicks elsewhere, and an add flow closes with it. Keep each step in one `&&` chain.
- `qfv quit` presses `Cancel` before it quits, so an open add flow does not block the cleanup.
