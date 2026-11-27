# Menu-bar batteries

The status item draws one battery per visible account, in the panel's order. Each battery shows how much of the week is left, or, by choice, the session, and a spent account says when it comes back. VoiceOver reads the whole strip as one sentence, which is also the item's accessibility label. With names hidden, each account is called by its provider.

## Sub-features

- `strip-batteries` draws one battery per visible account.
- `strip-sentence` speaks every account's session and week in one sentence, in panel order.
- `strip-states` speaks spent, waiting, signed-out and setup-issue accounts in words.
- `strip-empty` says no account is configured.
- `strip-session-picture` draws the batteries to the session instead of the week.
- `strip-hidden-names` replaces account names with their providers.

## How to get to it (user POV)

- Look at the menu bar.
- Hover the batteries for the tooltip, or move VoiceOver onto them.
- Choose Settings, General, Menu bar, `This session` or `This week`.
- Choose Settings, Privacy, `Hide account names`.

## Driving it with qfv

Preconditions:

- `"$Q" launch face` (or the scenario a step names), and `"$Q" doctor` reports `"ok":true`.

- **Read the sentence.** Run `"$Q" ax find id=qotafolio.statusItem`. The role is `AXMenuBarItem`, the help is `Open QotaFolio remaining quota`, and the label starts `QotaFolio. Personal: 53 percent left this week, 62 percent this session. Attilus: 38 percent left this week.` and ends `Spare: 12 percent left this week, 0 percent this session.` Each account's words are Kit's `AccountNow.MenuBar`. `Attilus` reads the week alone, as an account with no five-hour window does, with no "available now" clause.
- **Photograph the batteries.** Run `"$Q" shot strip id=qotafolio.statusItem --frame`. The PNG is the item's own rectangle, about 103 by 24 points for four accounts, with four batteries; the last is the spent one.
- **Read the states.** `"$Q" stop && "$Q" launch states`, then `"$Q" ax find id=qotafolio.statusItem`. The label contains `Work has no reading yet. Spare needs sign-in. Lab has a setup issue.`
- **Read the empty strip.** `"$Q" stop && "$Q" launch empty`. The `launch` output's `statusItem` is `QotaFolio. No accounts configured. Open QotaFolio to add one.`
- **Draw the session.** The week is the default. `"$Q" stop && "$Q" launch face QOTAFOLIO_UI_STRIP=session`, then `"$Q" shot strip-session id=qotafolio.statusItem --frame`. Compare with the week's shot: each account with a session is drawn to it, so its fill and colour differ. `Attilus`, which has no session, draws its week in both. `Spare`, with 12 percent of its week left and its session spent, changes most: a hairline in the session shot.
- **Hide names.** `"$Q" stop && "$Q" launch face QOTAFOLIO_UI_HIDE_NAMES=1`. The label reads `QotaFolio. Anthropic account: 53 percent left this week, … ChatGPT account: …` and contains no account name.
- **Proof.** The sentence before and after a change, from `"$Q" ax find id=qotafolio.statusItem`, plus the strip PNGs.

## Gotchas

- The sentence names both the week and an open session whichever one the batteries are drawn to. `strip-session-picture` can only be proven by the picture.
- On macOS 27 the system draws menu extras, so the item has no window of its own. A window shot fails; use `--frame`.
- A `--frame` shot is a screen capture of that rectangle. If the menu bar is hidden or another menu is open over the item, it captures that instead. Look at the PNG.
- The order follows the panel. A reorder in the panel (`../usage-panel.md`, `panel-reorder`) is the way to prove it.
