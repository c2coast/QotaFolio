# QotaFolio

QotaFolio is a macOS menu-bar app that shows how much usage each AI account has left. Version 1.0.0 is in `Sources/`. The rebuild puts the next version in new folders beside it.

## The folders

| Path | What it holds |
|---|---|
| `Sources/` | The code of version 1.0.0: the app, its widget, the `qota` command and their libraries. |
| `kit/` | The new tree's pure Swift, the `Kit` target. It uses Foundation only and has no clock and no files: the time comes in as a parameter. `tools/forecast` links it, and the app does not. |
| `kit/model/` | The values: `Percent`, `ResetTime`, `Limit`, `Reading`, `Verdict`, `Fall`, `Forecast`, `AccountForecast`, `WeekPicture`, `TimeWords`. |
| `kit/engine/forecast/` | The Engine: the verdicts of the week and the model's week at every poll, the falls, and the score against what then happened. |
| `kit/engine/week/` | The week picture at any moment, the account's forecast, the two sentences that say them, and the account's score. |
| `kit/tests/` | The Swift tests of `kit/`, the `KitTests` target. `fixtures/` holds the frozen record, its named moments, and the answers of the prototype and of the chart page on it. |
| `app/recorder/legacy/` | The reader of version 1.0.0's history file. It turns the file's bytes into readings. |
| `app/views/panel/graph/` | The Ceiling graph, the `Graph` target: its geometry, its colours in four forms, the view that draws them and what it says aloud. `tests/` holds its tests, the `GraphTests` target, and the worst weeks. `tools/forecast` links it, and the app does not. |
| `Assets/` | The app icon. |
| `project.yml` | The XcodeGen spec. XcodeGen writes `QotaFolio.xcodeproj` from it, and git ignores that project. |
| `Package.swift` | The Swift package of `QotaFolioModel` and `QotaFolioCore`, whose code is in `Sources/`. |
| `checks/` | The rules of the codebase, as node test files. |
| `tools/` | Scripts and tools. `tools/forecast` prints the forecast and its sentences on a recorded history, and draws the graph. It is the project's `forecast` target, which the app scheme builds too. `tools/release/ship.sh` is the release lane. `tools/make-battery-symbols.py` writes the battery symbols in `Sources/`. |
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
- **The Engine** makes a forecast from one account's readings. A forecast holds a verdict for the week and for the model's week at every poll: spent, silent with its reason, runs out at a time, or lasts with a landing. A limit of any other length has no verdict.
- **A fall** is a banked reset inside one week: points given back between two polls. One Fable point is half a weekly point.
- **The frozen record** is `kit/tests/fixtures/usage-history.json`: nine days of the owner's two accounts, A and B, in version 1.0.0's file. Every time is moved by a whole number of weeks, which changes no verdict.
- **The prototype's answer** is `kit/tests/fixtures/prototype.json`: the pace prototype's verdicts and scores on the frozen record. Nothing in this repository writes it.
- **Work** is a meter's reading plus the points falls gave back this week. The Engine calls it the cumulative. It never falls inside a week.
- **The account's forecast** says which limit the account meets first, and when: spent, the model's week spent, not started, silent, a limit runs out first, or the week lasts. On a tie it names the week.
- **The week picture** is one account's week at one poll, as the graph draws it: the week's bounds, its points with their work, the falls, the gaps, the stretches at the limit, the verdicts and the account's forecast. It holds no drawing.
- **The sentences** are the two lines under the graph: what the forecast says, and what the record shows. They are the chart page's words, and every time in them carries its day.
- **The time words** are `TimeWords` in `kit/model/`: how the product says a time, "Wed 21:00" on a 24-hour clock and "Wed 9:00 PM" on a 12-hour one. The sentences and the graph both say a time through them, so the two never disagree.
- **The chart page** is the web prototype whose graph the owner picked. **The chart page's answer** is `kit/tests/fixtures/chart-page.json`: the page's own code run on the frozen record, with its week, its forecast and its sentences at every poll. Nothing in this repository writes it.
- **The graph** is the Ceiling graph of one week picture: the work done as a line that never falls, under a ceiling that steps up at each banked reset, and the forecast running on to its ceiling. **The geometry** is the value `Ceiling`: everything the graph draws, in the chart's own points. The view only strokes it, and the tests read it.
- **A fold** is a stretch of the time axis in which nothing could happen, drawn as a narrow strip of fixed width: 34 points for a long stretch at the limit, 56 for the days after the forecast runs out or after the week was spent. `TimeAxis` holds the rule.
- **A label** is a word inside the plot. Each tries its places in order and takes the first free one; a forecast's label then tries its time alone. A label with no free place is left out, never drawn over another, because the sentences carry everything a label says. Two are always kept: the time the first limit runs out, and the week's limit. Every line stops short of a label, so a label on a line reads whole. `ChartType` measures a label and the canvas draws the same line of type.
- **The contrast** is measured from the colours as drawn, on the plate and on the band, in every look: the ceiling's line reaches 3 to 1, and every word 4.5 to 1. `ContrastTests` holds it.
- **A worst week** is a week the record does not hold, made up from readings in `app/views/panel/graph/tests/WorstWeeks.swift` and run through the Engine: a clock change, crowded banked resets, ceilings that meet, a long model name, a week's first poll. It is not a fixture. The labels' rule is tested on every worst week and every named moment, on both clocks, at 280, 360 and 520 points.
- **What the graph says aloud** is `SpokenGraph`: the graph's part of the card is one element, named by the caption's words, whose value is the forecast's sentence, followed by the record's. It offers VoiceOver's audio graph each limit's use, limit and forecast, on a time axis that says a clock time at each place.
- **A named moment** is a time of the frozen record with a name, such as `after-banked-reset`. `kit/tests/fixtures/moments.json` holds the chart page's twelve.

## The rules today

- Each wall in `checks/walls.mjs` holds for its folder.
- A fixture or a recording holds no email address, account id or home path. The repository is public.
- Every test is hostless.
- A hand-written code file in the new tree has 400 lines at most.

## Proving a change

1. Run `make check`. It runs every rule in about a second. It prints each breach, then a last line that starts with `check: pass` or `check: fail`.
2. If you changed Swift, run `make test`. It builds the app scheme unsigned, `tools/forecast` included, and runs the tests of `kit/` and of the graph with no host application. It prints each test, then a last line that starts with `test: pass` or `test: fail`.
3. If you changed the forecast or its sentences, run `tools/forecast`. It prints every poll's verdict for the week and the model's week, what then happened, and the account's two sentences. Then it prints the score of the week, of the model's week and of the account. Give it a path to read another history file, and `--json` for one line per poll with every number in full. `--at after-banked-reset` prints one named moment. `--at "2025-11-18 23:45"` prints one time in the Mac's zone, and `--account A` keeps one account.
4. If you changed the graph, run `tools/forecast --draw after-banked-reset`. It writes the graph's part of the card at that moment to a PNG, and prints the two sentences and the file's path. Nothing opens on screen: read the file. `--dark`, `--increased-contrast`, `--reduce-transparency` and `--12-hour` set the look, `--width` the chart's width in points, and `--out` names the file. The graph and the sentences say times in the Mac's zone, so `TZ=America/New_York tools/forecast --draw …` draws a week in New York. A run after a change builds the tool through its scheme, in a few seconds once `.build/` holds a build; a run with nothing changed takes a tenth of a second.
5. To build with no tests, follow "Build from source" in `README.md`. The build needs no signing. The app scheme builds the app and `tools/forecast` together.
6. The landing check runs the same rules, because they are tests. It also builds the app and runs its tests.

## Adding to the tree

- A new top-level folder adds its prefix to `.ci.toml` in the same pull request. If a rule reads the folder, its list has `node`.
- A new wall is a row in `checks/walls.mjs`. A new rule is a file `checks/<name>.test.mjs`.
- A rule arrives with the code that it fences. Show it red once on that code.
- A Swift test of `kit/` goes in `kit/tests/`. Its expected value comes from the owner's data, a case worked by hand, or the prototype, never from the code it tests.
