# Settings

The Settings window holds the user's choices in six tabs: General (open at login, appearance, what the batteries show, the panel shortcut, the `qota` path, Remove My Data), Accounts (order, visibility, add, per-account actions), Alerts, Privacy (hide names, hide them while the screen is shared), Updates and About. A choice takes effect at once in the panel and the menu bar.

## Sub-features

- `settings-open` opens Settings from the panel's footer.
- `settings-tabs` switches between the six tabs.
- `settings-strip-choice` chooses whether the batteries show the session or the week.
- `settings-appearance` chooses System, Light or Dark for QotaFolio's own windows.
- `settings-login` turns open-at-login on and off.
- `settings-reorder` moves an account up or down in the list, and so in the panel and the strip.
- `settings-hide-account` hides one account from the panel and the strip.
- `settings-hide-names` hides account names everywhere.

## How to get to it (user POV)

- Click the batteries, choose More in the footer, then `Settings…`.
- On a card with a setup issue, choose `Open Settings…`.

## Driving it with qfv

Preconditions:

- `"$Q" launch face`, and `"$Q" doctor` reports `"ok":true`.

- **Open Settings.** Run `"$Q" ax press id=qotafolio.statusItem && "$Q" ax wait id=qotafolio.footer.more 5 && "$Q" ax press id=qotafolio.footer.more && "$Q" ax wait id=qotafolio.footer.settings 3 && "$Q" ax press id=qotafolio.footer.settings && "$Q" ax wait 'role=AXWindow&label=QotaFolio Settings' 5`. A window titled `QotaFolio Settings` appears; `"$Q" ax windows` shows it on layer 0.
- **Switch tabs.** Run `"$Q" ax press 'role=AXRadioButton&label=Accounts'`. In the toolbar's `AXTabGroup`, `Accounts` has value `1`; the content heading is `Accounts` and lists each account with `More actions for <name>`, a `Show account` switch, `Up` and `Down`. The other tabs are `General`, `Alerts`, `Privacy`, `Updates`, `About`.
- **Batteries to the week.** On General run `"$Q" ax press 'role=AXRadioButton&label=This week'`. That radio's value is `1` and `This session` is `0` in `qotafolio.settings.stripShows`.
- **Appearance.** On General run `"$Q" ax press 'role=AXRadioButton&label=Dark'`. In `qotafolio.settings.appearance`, `Dark` has value `1`; a shot of the window shows it dark.
- **Open at login.** On General run `"$Q" ax press id=qotafolio.settings.launchAtLogin`. Its value goes from `0` to `1`. The lab uses a stand-in for the login item, so nothing is registered with macOS.
- **Move an account up.** On Accounts run `"$Q" ax press 'role=AXButton&label=Up&nth=2'`. The second account moves first, and `"$Q" ax find id=qotafolio.statusItem` speaks it first: in `face`, the sentence starts `QotaFolio. Attilus:`.
- **Hide an account.** On Accounts run `"$Q" ax press 'role=AXCheckBox&label=Show account&nth=2'`. A user expects `Personal` to leave the strip's sentence. Through this harness the switch stays on: this journey fails. See Gotchas.
- **Hide names.** On Privacy run `"$Q" ax press id=qotafolio.settings.privacy.hideNames`, then `"$Q" ax find id=qotafolio.statusItem`. The checkbox value flips, and the strip's sentence switches between account names and `Anthropic account` / `ChatGPT account`. `"$Q" launch face QOTAFOLIO_UI_HIDE_NAMES=1 QOTAFOLIO_UI_OPEN_SETTINGS=privacy` starts with names hidden and this tab open.
- **Proof.** `"$Q" snap settings-<tab>` and `"$Q" shot settings-<tab> 'role=AXWindow&label=QotaFolio Settings'` for each tab you change, before and after.

## Gotchas

- `settings-hide-account` fails through this harness. AXPress on the second `Show account` switch reports success, but the switch stays on (value `1`, and the window shot shows it on), and the strip still speaks every account. The `Open QotaFolio at login` switch on General is the same control style and does flip under AXPress, so the harness can drive switches; what stops this row is not yet determined. Check it with VoiceOver and with a pointer before calling it a product defect.
- The `Show account`, `Up` and `Down` controls carry no per-account identifier. Select them with `label=` and `nth=` in list order, which is the account order.
- macOS 27 exposes the tab bar as `AXToolbar` › `AXTabGroup` › `AXRadioButton`. Older code that looks for an `AXRadioGroup` of tabs finds nothing.
- Settings is an ordinary window. It can sit behind the owner's windows; a window shot still captures it whole.
- Do not press `Remove My Data…` (`qotafolio.settings.uninstall`), the shortcut recorder or the Terminal row's `Copy`. The first is out of scope for a fixture, the second listens for keys, the third replaces the owner's clipboard.
- Choices live in the lab's own settings domain, one for each lane. The lab empties it when it starts and when it quits.
