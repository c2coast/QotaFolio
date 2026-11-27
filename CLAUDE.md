# QotaFolio

QotaFolio is a macOS menu-bar app that shows how much usage each AI account has left. Most of the app is still the code of version 1.0.0, in `Sources/`. The rebuild puts the next version in new folders beside it.

## The folders

| Path | What it holds |
|---|---|
| `Sources/` | The code of version 1.0.0: the app, the `qota` command and their libraries. |
| `kit/` | The new tree's pure Swift, the `Kit` target. It uses Foundation only and has no clock and no files: the time comes in as a parameter. `tools/forecast` links it. The app reaches only its design values, through `QotaFolioKit`. |
| `kit/design/` | The design values as Swift. `Tokens.swift` is generated from `design/tokens.json`, and `Design.swift` holds their shapes and `Level`, the three steps of a level. |
| `kit/model/` | The values: `Percent`, `ResetTime`, `Limit`, `Reading`, `Verdict`, `Fall`, `Forecast`, `AccountForecast`, `WeekPicture`, `TimeWords`, `Whole`, `AccountNow`, `SpentLimitBack`. |
| `kit/engine/forecast/` | The Engine: the verdicts of the week and the model's week at every poll, the falls, and the score against what then happened. |
| `kit/engine/week/` | The week picture at any moment, the account's forecast, the two sentences that say them, the account now, a spent limit that is back, and the account's score. |
| `kit/tests/` | The Swift tests of `kit/`, the `KitTests` target. `fixtures/` holds the frozen record, its named moments, and the answers of the prototype and of the chart page on it. |
| `app/` | The app's code in the new tree. The app compiles `app/lease/`, `app/settings/legacy/` and `app/settings/hidden/`, and signs with the entitlements file in `app/main/`. `qota` compiles `app/settings/hidden/` too. Tools and tests link the other folders. |
| `app/main/` | The app's entitlements file, and `tests/AppIdentityTests.swift`, the part of `AppTests` that pins the names `AppIdentity` derives. |
| `app/lease/` | The lease. `tests/` holds its tests, in `AppTests`. |
| `app/settings/legacy/` | The carry. `tests/` holds its tests, in `AppTests`. |
| `app/settings/hidden/` | The hidden accounts: the key under which the app keeps the list in its preferences domain, and the filter that leaves them out of `qota status`. `tests/` holds its tests, in `AppTests`. |
| `app/recorder/legacy/` | The reader of version 1.0.0's books: the trace and the snapshots, as the files' bytes, into each account's readings. |
| `app/views/panel/graph/` | The Ceiling graph, the `Graph` target: its geometry, its colours in every look from the design values, the view that draws them and what it says aloud. `tests/` holds its tests, the `GraphTests` target, and the worst weeks. `tools/forecast` links it, and the app does not. |
| `design/` | `tokens.json`: the design values, every value that carries a decision of the look, each with its why. |
| `Assets/` | The app icon. |
| `project.yml` | The XcodeGen spec. XcodeGen writes `QotaFolio.xcodeproj` from it, and git ignores that project. |
| `Package.swift` | The Swift package of `QotaFolioModel` and `QotaFolioCore`, whose code is in `Sources/`. |
| `checks/` | The rules of the codebase, as node test files. |
| `Makefile` | `make check` and `make test`. |
| `tools/` | Scripts and tools. `tools/forecast` prints the forecast and its sentences on a recorded history, and draws the graph. It is the project's `forecast` target, which the app scheme builds too. `tools/gen` writes every generated file from its source. `tools/release/ship.sh` is the release lane. |
| `docs/` | The release documents and the pictures in `README.md`. |
| `.ci.toml` | The stacks of the landing check that read each path. |
| `.mcp.json`, `.xcodebuildmcp/` | The MCP servers a session in this repository starts, and the macOS tools of XcodeBuildMCP. |
| `.claude/skills/verify-qotafolio/` | The verify skill: the lab, driven by `bin/qfv`. Git ignores the rest of `.claude/`. |

## The words

- **The identity** is the app's bundle identifier. `AppIdentity` derives every name the app owns from it and the signing team: its App Group, its preferences domain, its Keychain service and its support folder. The release is `net.c2coast.QotaFolio`, and a development build adds `.dev`.
- **The lease** is a locked file in the identity's support folder. It lets one copy of each identity run. Version 1.0.0 keeps its own lease inside its sandbox container, where this lease cannot see it. So `AppDelegate` makes a second check: it refuses to start while another process runs with the same identifier.
- **The carry** copies the settings of version 1.0.0, once, from its sandbox container into the app's preferences domain.
- **The lab** is the fixture runtime, `FixtureAppRuntime`: the real app over invented accounts, which every Debug build carries. The verify skill drives it under its own identity, `net.c2coast.QotaFolio.dev.verify`, so it runs beside the installed app.
- **The old tree** is `Sources/`. No rule reads it. Put new code in the new tree.
- **The new tree** is every folder except `Sources/` and `.claude/`.
- **A rule** is a test in `checks/` that reads the source of the new tree.
- **A wall** is a rule about one folder: the modules its Swift files may import and the calls they may not make. `checks/walls.mjs` holds the walls.
- **A breach** is one place that breaks a rule. It prints as `file:line` and then the fix.
- **A fixture** is data in a `fixtures/` folder. **A recording** is data in a `recordings/` folder.
- **A hostless test** puts nothing on screen and does not use the login Keychain.
- **The landing check** is the `check` of `c2coast/ci`. It runs once for each pull request, on a fresh clone, when the pull request lands.
- **A reading** is what one poll of an account said: each limit, how much of it is used, and when it resets.
- **A limit** is the week, a model's week such as Fable's, a session, or any other length a provider sends.
- **The Engine** makes a forecast from one account's readings: a verdict for the week and for the model's week at every poll. A limit of any other length has no verdict.
- **A fall** is a banked reset inside one week: points given back between two polls. One Fable point is half a weekly point.
- **Work** is a meter's reading plus the points falls gave back this week. It never falls inside a week.
- **The account's forecast** is `AccountForecast`: which limit the account meets first, and when.
- **The week picture** is `WeekPicture`: one account's week at one poll, as the graph draws it.
- **The sentences** are the two lines under the graph: what the forecast says, and what the record shows.
- **The time words** are `TimeWords`, and **whole numbers** are `Whole`. The sentences, the rows and the graph say every time and every number through them, so they never disagree. The time words are said at a moment: a time seven days or more from its day says its date too, "Wed 26 Nov 21:00".
- **The account now** is `AccountNow`: everything the app says of one account at one moment. A row for each limit of the newest reading, the week picture and its sentences, the menu bar's week, and each spent limit that is back. Kit builds it from the readings and the time words, on this week and the poll before it. A forecast for a week whose reset has passed is not said.
- **A spent limit is back** is `SpentLimitBack`, the alert's condition: a limit read 100 percent, then less, or its reset passed. It is keyed by the account, the limit, the reset it was spent until, and how it came back.
- **The frozen record** is `kit/tests/fixtures/usage-history.json`: nine days of the owner's two accounts in version 1.0.0's file, with every time moved by a whole number of weeks.
- **A named moment** is a time of the frozen record with a name, such as `after-banked-reset`. `kit/tests/fixtures/moments.json` holds them.
- **The chart page** is the web prototype whose graph the owner picked, and **the prototype** is the pace prototype. Their answers on the frozen record are `chart-page.json` and `prototype.json` in `kit/tests/fixtures/`. The Engine departs from them on one rule: the minutes after a reset are not blocked. `prototype-after-reset.json` and `chart-page-after-reset.json` hold their answers with that one line changed, at each poll where it moves them. Nothing in this repository writes them.
- **The graph** is the Ceiling graph of one week picture: the work done, as a line under a ceiling that steps up at each banked reset. **The geometry** is `Ceiling`: everything the graph draws, in the chart's own points. The view only strokes it.
- **A fold** is a stretch of the time axis in which nothing could happen, drawn as a narrow strip. `TimeAxis` holds the rule and its widths.
- **A label** is a word inside the plot, placed by `Placement.swift`. A forecast's label takes a place by its own dot, nearer it than the marks of now, when one is free, and otherwise the first free place. A label with no free place is left out, never drawn over another label or the record, because the sentences say everything a label says. `LabelTests` checks the rule in every named moment and worst week, on both clocks, at the widths it names. It holds that two labels are kept in every week it knows: the time the first limit runs out, and the week's limit.
- **A look** is light or dark, with Increase Contrast or without, and with Reduce Transparency or without.
- **The contrast** is measured in every look, on the plate and on the band: 3 to 1 for the ceiling, 4.5 to 1 for every word. `ContrastTests` holds it.
- **A worst week** is a made-up week the record does not hold, run through the Engine. The header of `app/views/panel/graph/tests/WorstWeeks.swift` lists them.
- **A design value** is one entry of `design/tokens.json`: one value, or a value in each look it varies over, with its why. Kit's `Tokens` holds them in Swift. The app turns them into colours, fonts and animations in `Sources/QotaFolioKit/Panel/PanelDesign.swift`. The graph turns them in `Palette.swift` and `ChartType.swift`. Each side builds a colour the way it drew it before the values had a home, because two ways of writing the same numbers can give different pixels.
- **A type role** is a size, a weight, and whether the digits are monospaced, such as `title` or `captionFigures`.
- **A generated file** is written by `tools/gen` from its source and committed. `kit/design/Tokens.swift` is one.
- **What the graph says aloud** is `SpokenGraph`: one VoiceOver element with the two sentences, and an audio graph of the week and the model's week.

## The rules today

- Each wall in `checks/walls.mjs` holds for its folder.
- A fixture or a recording holds no email address, account id or home path. The repository is public.
- Every test is hostless.
- The app runs outside the App Sandbox. No entitlements file and no setting in `project.yml` asks for the sandbox or for a sandbox exception.
- The build number in `project.yml` is a whole number above 100, the build of version 1.0.0. Version 1.0.0 updates only to such a number.
- A hand-written code file in the new tree has 400 lines at most. A generated file does not count.
- A generated file holds exactly what `tools/gen` makes of its source.
- Outside tests and generated files, the new tree's Swift writes no font size and no colour as numbers. It reads `Tokens`.

## Proving a change

1. Run `make check`. It runs every rule in about a second. It prints each breach, then a last line that starts with `check: pass` or `check: fail`.
2. If you changed Swift, run `make test`. It builds the app scheme unsigned, `tools/forecast` included, and runs `KitTests`, `GraphTests` and `AppTests` with no host application. It prints each test, then a last line that starts with `test: pass` or `test: fail`.
3. If you changed the forecast or its sentences, run `tools/forecast`. It prints every poll's verdict for the week and the model's week, what then happened, and the account's two sentences. Then it prints the score of the week, of the model's week and of the account. Give it a path to read another history file, and `--json` for one line per poll with every number in full. `--at after-banked-reset` prints one named moment. `--at "2025-11-18 23:45"` prints one time in the Mac's zone, and `--account A` keeps one account.
4. If you changed the graph, run `tools/forecast --draw after-banked-reset`. It writes the graph's part of the card at that moment to a PNG, and prints the two sentences and the file's path. Nothing opens on screen: read the file. `--dark`, `--increased-contrast`, `--reduce-transparency` and `--12-hour` set the look, `--width` the chart's width in points, and `--out` names the file. The graph and the sentences say times in the Mac's zone, so `TZ=America/New_York tools/forecast --draw …` draws a week in New York. A run after a change builds the tool through its scheme, in a few seconds once `.build/` holds a build; a run with nothing changed takes a tenth of a second.
5. If you changed what a person sees or does in the app, prove it on the app itself with the lab. Read `.claude/skills/verify-qotafolio/SKILL.md`. A launch puts the lab's item in the owner's menu bar, so ask him first.
6. To build with no tests, follow "Build from source" in `README.md`. The build needs no signing. The app scheme builds the app and `tools/forecast` together.
7. The landing check runs the same rules, because they are tests. It also builds the app and runs its tests.

## Changing a design value

1. Change the value, or add one with its why, in `design/tokens.json`.
2. Run `tools/gen`. It writes `kit/design/Tokens.swift`. Commit both.
3. Run `make check` and `make test`. A graph change shows in `tools/forecast --draw`. A change the app shows is proved on the app, as step 5 of "Proving a change" says.

Never edit `Tokens.swift` by hand: `make check` refuses it and names the command. A new kind of value, such as a new shape of colour, is a case in `kit/design/Design.swift`, a form `tools/gen.mjs` reads, and a case where each side turns it into what it draws: `PanelDesign.swift` for the app, and `Palette.swift` or `ChartType.swift` for the graph.

## Adding to the tree

- A new top-level folder adds its prefix to `.ci.toml` in the same pull request. If a rule reads the folder, its list has `node`.
- A new wall is a row in `checks/walls.mjs`. A new rule is a file `checks/<name>.test.mjs`.
- A rule arrives with the code that it fences. Show it red once on that code.
- A Swift test of `kit/` goes in `kit/tests/`. Its expected value comes from the owner's data, a case worked by hand, or the prototype, never from the code it tests.
