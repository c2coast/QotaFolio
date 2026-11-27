# Usage panel

The panel opens under the menu-bar batteries and shows one card per visible account: the provider, the plan, each usage window with its percentage used and its reset time, and a state line when the account is stale, waiting, signed out or misconfigured. A card opens to show its plan and spend. The footer adds an account and holds Refresh, Settings and Quit.

## Sub-features

- `panel-open` opens the panel from the menu-bar batteries.
- `panel-cards` shows one card per account, with a spoken summary of every window.
- `panel-states` shows stale numbers, a waiting account, a signed-out account and a setup issue, each with its own action.
- `panel-details` opens a card to show its plan and its extra usage or credits.
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
- **Read the cards.** Run `"$Q" snap panel-open && "$Q" shot panel-open id=qotafolio.panel`. In `face`, `qotafolio.accounts.list` holds four `AXButton`s with ids `qotafolio.account.00000000-0000-4000-8000-00000000000N.summary`. Their labels are `Personal, Anthropic`, `Attilus, Anthropic`, `Work, ChatGPT` and `Spare, ChatGPT`. Each value reads like `Max 20x. Session, 38 percent used. Resets in 2 hours 37 minutes. Weekly, 47 percent used. …`. The `Spare` value starts `Pro 20x. Spent, back at`. The PNG shows four cards with bars and reset times.
- **See every state.** With `states`, the same chain shows `Waiting for the first reading.` on `Work`, `Needs sign-in.` plus a `Sign In…` button (`….000000000004.reauthenticate`) on `Spare`, `Setup issue.` plus `Open Settings…` (`….000000000005.openSettings`) on `Lab`, and `Numbers as of <time>.` at the end of the `Attilus` value.
- **Open a card.** Click a card. Run `"$Q" ax press id=qotafolio.account.00000000-0000-4000-8000-000000000001.summary && sleep 1 && "$Q" snap card-open`. Static texts `Max 20x` and `Extra usage £12.40 of £150.00 this month` appear inside that card, and the panel frame grows taller. `Spare` shows `796 credits ($31.84)`, and an account with neither shows `No extra usage`.
- **Move an account up.** Choose More on the second card, then Move Up. Run `"$Q" ax press id=qotafolio.account.00000000-0000-4000-8000-000000000002.moreActions && "$Q" ax press id=qotafolio.account.00000000-0000-4000-8000-000000000002.moveUp`. The first summary in the tree is now `Attilus`, and `"$Q" ax find id=qotafolio.statusItem` speaks `Attilus` before `Personal`.
- **Use the footer.** Choose More in the footer. Run `"$Q" ax press id=qotafolio.footer.more && "$Q" ax wait id=qotafolio.footer.quit 3`. The menu holds `Refresh Now` (`qotafolio.footer.refresh`), `Settings…` (`qotafolio.footer.settings`) and `Quit QotaFolio` (`qotafolio.footer.quit`).
- **Start the app again.** Close the panel by pressing the batteries once more, then run `"$Q" reopen && "$Q" ax wait id=qotafolio.panel 3`. `qfv reopen` starts a second process of the lane's build. That process exits 0, the first keeps its pid, and the panel is open.
- **Quit.** Run `"$Q" quit`. It prints `exitedAfterMs`; `"$Q" doctor` then shows `"pid":null`.
- **Proof.** `panel-open.ax.json` and `panel-open.png` in the run folder show the four accounts, and `"$Q" qota status` lists the same four accounts with the same percentages and reset times.

## Gotchas

- The panel closes when the owner clicks anywhere else, as it does for any user. A step that prints `no element matches` after the panel was open means it closed; open it again in the same chain as the step.
- `face`, `states` and `new-account` count from the launch time, so reset times differ run to run. Assert the shape (`percent used`, `Resets in`), not the clock.
- `Refresh Now` in a fixture changes nothing on screen. The fixture store counts the request and has no poller behind it.
- The panel shot is a window capture, so its glass is a flat grey. See Evidence in `../SKILL.md` for a picture with glass.
- A card's More button and the footer's More button both carry the label `More`. Select them by id.
- Finder, Spotlight and the Dock start no second process when the app already runs. They send the running app a reopen event, and this lab sends none, so that entry point is not verified here. `qfv reopen` proves the second-copy path only.
- The ⌃⌥Q shortcut would need a synthetic key press. This lab posts none, so that entry point is not verified here.
