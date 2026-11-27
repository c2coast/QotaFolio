# Alerts

QotaFolio shows one kind of alert: a spent limit is back. When a poll finds that a limit which had reached 100 percent has come back, by its reset or by a banked reset, the app shows one banner that names the account, the limit and the reset with its day, such as `Personal's week is back. It reset Wed 21:00.` Each event is shown once, however many polls read it again. Settings has one switch for all alerts and one switch per account, and macOS asks for permission the first time an alert is due.

## Sub-features

- `alert-back` shows one alert when a poll finds a spent limit back.
- `alert-once` shows it once when the next poll reads the same.

## How to get to it (user POV)

- Use an account until a limit is spent, then wait for its reset. The banner appears at the first poll after the limit comes back.
- Settings, Alerts holds the switch for all alerts and one per account.

## Driving it with qfv

Preconditions:

- `"$Q" launch face QOTAFOLIO_UI_ALERTS=1`, and `"$Q" doctor` reports `"ok":true`.
- The lab replaces macOS's notification centre with a recording one, so nothing appears on screen and nothing is asked. Each delivered alert is a `QF_ALERT` line in `qfv log`.

- **One alert.** Three seconds after the launch, run `"$Q" log`. One poll arrives that reads `Spare`'s spent session at nothing. The log holds one line `QF_ALERT id=back|00000000-0000-4000-8000-000000000004||session|<seconds>|reset body=Spare's session is back. It reset <day> <time>.`
- **Once.** A second poll a second later reads the same. The log still holds one `QF_ALERT` line.
- **Proof.** The `app.log` in the run folder, and `"$Q" clean` after.

## Gotchas

- The face scenario has no poll that brings a limit back, so `QOTAFOLIO_UI_ALERTS=1` makes one. The alert then says the session reset at that poll's minute, not at the reset time the card showed.
- The fixture's settings are emptied at every launch, so a second launch shows the alert again. Within one run it shows once.
