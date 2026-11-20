# QotaFolio

QotaFolio is a macOS menu-bar app that shows how much usage each AI account has left. Version 1.0.0 is in `Sources/`. The rebuild puts the next version in new folders beside it.

## The folders

| Path | What it holds |
|---|---|
| `Sources/` | The code of version 1.0.0: the app, its widget, the `qota` command and their libraries. |
| `kit/` | The new tree's pure Swift, the `Kit` target. It uses Foundation only and has no clock and no files: the time comes in as a parameter. The app does not link it yet. |
| `kit/model/` | The values: `Percent`, `ResetTime`, `Limit`, `Reading`, `Verdict`, `Fall`, `Forecast`. |
| `kit/engine/forecast/` | The Engine: the forecast for each limit at every poll, the falls, and the score against what then happened. |
| `kit/tests/` | The Swift tests of `kit/`, the `KitTests` target. `fixtures/` holds the frozen record and the prototype's answer on it. |
| `app/recorder/legacy/` | The reader of version 1.0.0's history file. It turns the file's bytes into readings. |
| `Assets/` | The app icon. |
| `project.yml` | The XcodeGen spec. XcodeGen writes `QotaFolio.xcodeproj` from it, and git ignores that project. |
| `Package.swift` | The Swift package of `QotaFolioModel` and `QotaFolioCore`, whose code is in `Sources/`. |
| `checks/` | The rules of the codebase, as node test files. |
| `tools/` | Scripts. `tools/forecast` prints the forecast on a recorded history. `tools/release/ship.sh` is the release lane. `tools/make-battery-symbols.py` writes the battery symbols in `Sources/`. |
| `docs/` | The release documents and the pictures in `README.md`. |
| `.ci.toml` | The stacks of the landing check that read each path. |

## The words

- **The old tree** is `Sources/`. No rule reads it. Put new code in the new tree.
- **The new tree** is every folder except `Sources/`.
- **A rule** is a test in `checks/` that reads the source of the new tree.
- **A wall** is a rule about one folder. It names the modules a Swift file in that folder may import and the calls it may not make. `checks/walls.mjs` holds the walls.
- **A breach** is one place that breaks a rule. It prints as `file:line` and then the fix.
- **A fixture** is data in a `fixtures/` folder. **A recording** is data in a `recordings/` folder.
- **A hostless test** puts nothing on screen and does not use the login Keychain.
- **The landing check** is the `check` of `c2coast/ci`. It runs once for each pull request, on a fresh clone, when the pull request lands.
- **A reading** is what one poll of an account said: each limit, how much of it is used, and when it resets.
- **A limit** is the week, a model's week such as Fable's, a session, or any other length a provider sends. Its kind is which limit it is.
- **The Engine** makes a forecast from one account's readings. A forecast holds a verdict for each limit at every poll: spent, silent with its reason, runs out at a time, or lasts with a landing.
- **A fall** is a banked reset inside one week: points given back between two polls. One Fable point is half a weekly point.
- **The frozen record** is `kit/tests/fixtures/usage-history.json`: nine days of the owner's two accounts, A and B, in version 1.0.0's file. Every time is moved by a whole number of weeks, which changes no verdict.
- **The prototype's answer** is `kit/tests/fixtures/prototype.json`: the pace prototype's verdicts and scores on the frozen record. Nothing in this repository writes it.

## The rules today

- Each wall in `checks/walls.mjs` holds for its folder.
- A fixture or a recording holds no email address, account id or home path. The repository is public.
- Every test is hostless.
- A hand-written code file in the new tree has 400 lines at most.

## Proving a change

1. Run `make check`. It runs every rule in about a second. It prints each breach, then a last line that starts with `check: pass` or `check: fail`.
2. If you changed Swift, run `make test`. It builds the app scheme unsigned and runs its tests with no host application. It prints each test, then a last line that starts with `test: pass` or `test: fail`.
3. If you changed the forecast, run `tools/forecast`. It prints every poll's verdict for each limit, what then happened, and each limit's score. Give it a path to read another history file, and `--json` for one line per poll with every number in full.
4. The build needs no signing. To build the app alone:

	```bash
	xcodegen generate --no-env --spec project.yml --project . --project-root .
	xcodebuild -project QotaFolio.xcodeproj -scheme QotaFolio -configuration Debug \
	  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
	```

5. The landing check runs the same rules, because they are tests. It also builds the app and runs its tests.

## Adding to the tree

- A new top-level folder adds its prefix to `.ci.toml` in the same pull request. If a rule reads the folder, its list has `node`.
- A new wall is a row in `checks/walls.mjs`. A new rule is a file `checks/<name>.test.mjs`.
- A rule arrives with the code that it fences. Show it red once on that code.
- A Swift test of `kit/` goes in `kit/tests/`. Its expected value comes from the owner's data, a case worked by hand, or the prototype, never from the code it tests.
