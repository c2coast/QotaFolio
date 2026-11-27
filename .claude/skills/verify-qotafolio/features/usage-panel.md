# Usage panel

The panel opens under the menu-bar batteries and shows one card per visible account: the provider, the plan, each limit with its percentage used, its reset with its day and, for the week and the model's week, whether it lasts, and a state line when the account is stale, waiting, signed out or misconfigured. A card opens to show the account's week as a graph with two sentences under it, what the forecast says and what the record shows, then its plan and spend. The footer adds an account and holds Refresh, Settings and Quit.

## Sub-features

- `panel-open` opens the panel from the menu-bar batteries.
- `panel-cards` shows one card per account, with a spoken summary of every window.
- `panel-states` shows stale numbers, a waiting account, a signed-out account and a setup issue, each with its own action.
- `panel-details` opens a card to show the week's graph and its two sentences, then its plan and its extra usage or credits.
- `panel-reorder` moves an account up or down from the card's More menu.
- `panel-footer` offers Add Account and a More menu with Refresh Now, Settings and Quit.
- `panel-reopen` shows the panel when a second copy of the app starts while the first runs.
- `panel-quit` quits the app from the footer.

## How to get to it (user POV)

- Click the batteries in the menu bar.
- Open a second copy of the same build while the first runs. It shows the first copy's panel and quits.
- Open QotaFolio again from Finder, Spotlight or the Dock while it runs (not driven here; see Gotchas).
- Press the panel shortcut, ⌃⌥Q by default (not driven here; see Gotchas).

## Driving it with qfv

Preconditions:

- `"$Q" launch face` for the four-account fleet, or `"$Q" launch states` for `panel-states`.
- `"$Q" doctor` reports `"ok":true` and `"panelOpen":false`.

- **Open the panel.** Click the batteries. Run `"$Q" snap before-open && "$Q" ax press id=qotafolio.statusItem && "$Q" ax wait id=qotafolio.panel 5`. The wait prints `"ok":true` and the panel's frame, about 408 by 620 points under the batteries.
- **Read the cards.** Run `"$Q" snap panel-open && "$Q" shot panel-open id=qotafolio.panel`. In `face`, `qotafolio.accounts.list` holds four `AXButton`s with ids `qotafolio.account.00000000-0000-4000-8000-00000000000N.summary`. Their labels are `Personal, Anthropic`, `Attilus, Anthropic`, `Work, ChatGPT` and `Spare, ChatGPT`. Each value is the plan, then each limit's row in Kit's words, the week first: `Max 20x. Weekly, 47% used, resets <day> <time>, <verdict>. Fable, 8% used, … Session, 38% used, resets <day> <time>.` A session row has no verdict, and neither has a row whose forecast is silent, such as `Attilus`'s `Weekly, 62% used, resets <day> <time>.` `Attilus` has a week and no session. The `Spare` value starts `Pro 20x. Spent, back <day> <time>.` The PNG shows four cards, each limit with its bar, its reset with its day and, under the bar, the verdict when the forecast speaks.
- **See every state.** With `states`, the same chain shows `Waiting for the first reading.` on `Work`, `Needs sign-in.` plus a `Sign In…` button (`….000000000004.reauthenticate`) on `Spare`, `Setup issue.` plus `Open Settings…` (`….000000000005.openSettings`) on `Lab`, and `Numbers as of <day> <time>.` at the end of the `Attilus` value. `Attilus`'s week came with no reset, so its row has none.
- **Open a card.** Click a card. Run `"$Q" ax press id=qotafolio.account.00000000-0000-4000-8000-000000000001.summary && sleep 1 && "$Q" snap card-open`. The card shows the Ceiling graph of the week, one element whose label is the forecast's sentence, with the two sentences under it, then static texts `Max 20x` and `Extra usage £12.40 of £150.00 this month`, and the panel frame grows taller. `Spare` shows `796 credits ($31.84)`, and an account with neither shows `No extra usage`. A card with no week to draw shows one sentence that says why: in `states`, `Attilus` says `The provider gave no reset for the week, so there is no week to draw.`
- **Move an account up.** Choose More on the second card, then Move Up. Run `"$Q" ax press id=qotafolio.account.00000000-0000-4000-8000-000000000002.moreActions && "$Q" ax press id=qotafolio.account.00000000-0000-4000-8000-000000000002.moveUp`. The first summary in the tree is now `Attilus`, and `"$Q" ax find id=qotafolio.statusItem` speaks `Attilus` before `Personal`.
- **Use the footer.** Choose More in the footer. Run `"$Q" ax press id=qotafolio.footer.more && "$Q" ax wait id=qotafolio.footer.quit 3`. The menu holds `Refresh Now` (`qotafolio.footer.refresh`), `Settings…` (`qotafolio.footer.settings`) and `Quit QotaFolio` (`qotafolio.footer.quit`).
- **Start the app again.** Close the panel by pressing the batteries once more, then run `"$Q" reopen && "$Q" ax wait id=qotafolio.panel 3`. `qfv reopen` starts a second process of the lane's build. That process exits 0, the first keeps its pid, and the panel is open.
- **Quit.** Run `"$Q" quit`. It prints `exitedAfterMs`; `"$Q" doctor` then shows `"pid":null`.
- **Proof.** `panel-open.ax.json` and `panel-open.png` in the run folder show the four accounts, and `"$Q" qota status` lists the same four accounts with the same percentages and reset times.

## Gotchas

- The panel closes when the owner clicks anywhere else, as it does for any user. A step that prints `no element matches` after the panel was open means it closed; open it again in the same chain as the step.
- `face`, `states` and `new-account` count from the launch time, so reset times differ run to run. Assert the shape (`% used`, `resets <day> <time>`), not the clock.
- `Refresh Now` in a fixture changes nothing on screen. The fixture store counts the request and has no poller behind it.
- The panel shot is a window capture, so its glass is a flat grey. See Evidence in `../SKILL.md` for a picture with glass.
- A card's More button and the footer's More button both carry the label `More`. Select them by id.
- Finder, Spotlight and the Dock start no second process when the app already runs. They send the running app a reopen event, and this lab sends none, so that entry point is not verified here. `qfv reopen` proves the second-copy path only.
- The ⌃⌥Q shortcut would need a synthetic key press. This lab posts none, so that entry point is not verified here.
