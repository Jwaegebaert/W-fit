# Watch app

Companion for Wear OS watches (built for a Galaxy Watch5 Pro). During a workout on the phone the watch shows the current
exercise, runs the rest and work timers with vibration, and logs sets.

- `watch/`: native Kotlin, Compose for Wear, its own Gradle build. `flutter build apk` does not touch it.
- `app/lib/features/watch/`, `WatchBridge.kt`: the phone side.

## Using it
| On the watch | What it does |
|---|---|
| Swipe up / down or turn the bezel | Other exercises |
| Log 2/3 | Logs the set with the numbers above the button and starts the rest |
| The numbers (pencil) | Change reps and weight (buttons or bezel), log, or undo the last set |
| Done (warm-up, cool-down) | Ticks off the whole exercise, without rest; *Undo* takes it back |
| ♥ 128 | Live heart rate, if allowed; only while the workout is on screen |
| Start 1/2 | Work timer; one-sided holds run both sides with 5 s to switch, then the set is logged. One-sided stretches run both rounds in one go |
| −15, +15, Skip / Stop | Change or end the timer; *Log now* ends a hold early and logs it |
| Swipe right on the timer | Back to the exercise; the timer keeps running and shows on top |

Vibration: three pulses = rest over, two short = switch sides, one short = other side starts, one long = hold done.

On machines with a numbered stack the watch shows and logs plate numbers; the phone turns them into kg.

Finishing or discarding a workout, swaps and notes stay on the phone. The watch never records a workout of its own, so
Samsung Health and Health Connect get no second entry.

## How it works
The phone's database owns the session. Both directions use data items of the Wearable Data Layer, which Google Play
services stores and delivers when the devices are back in reach.

| Path | From | Content |
|---|---|---|
| `/wfit/session` | phone | Snapshot: exercises with ready-made labels, logged sets, the timer, handled event ids |
| `/wfit/event/<id>` | watch | One logged or undone set; removed once the phone lists its id as handled |
| `/wfit/timer` | watch | The watch's last timer change |

- **Sets.** Matched on session, exercise position, exercise and set number; the newest entry wins (whole seconds). An
  event can arrive late, twice or out of order. A set for a finished workout is still added; for a discarded one dropped.
- **Timers.** Absolute end times plus the planned sequence (side 1, switch, side 2, rest), so both devices calculate the same
  thing. The newest change wins. Only the device that started a work timer logs its set.
- **Vibration.** An alarm clock alarm per phase (`USE_EXACT_ALARM`): works with the screen off and the app closed.
- **Warm-up and cool-down** follow the phone's checklist: all sets at once, no rest, no weight. The watch never sends you
  back to a skipped warm-up.
- **Heart rate** comes straight from the sensor and is only shown: not stored, not sent, and no exercise is started. The
  average and maximum still come from Health Connect after the workout.
- **Phone asleep or closed.** Sets wait and are stored when the app wakes or is opened.
- **Old workouts.** A session without end is hidden after 8 hours.

`watch/fixtures/` holds example messages and timer cases. Both test suites use them
(`app/test/watch_sync_test.dart`, `app/test/workout_countdown_test.dart`, `watch/app/src/test`), so a change on one side
only fails a test. A breaking change to the messages needs a new `watchProtocolVersion` / `PROTOCOL_VERSION`.

## Building
```powershell
./watch/build.ps1
```
Runs the tests and builds `watch/app/build/outputs/apk/release/app-release.apk`. Both apps must have the same
application id (`com.jwaegebaert.wfit`) and be signed with the same key: build them on the same PC.

## Installing on the watch
Watch and PC must be on the same Wi-Fi.

1. Watch: *Settings > About watch > Software information*, tap *Software version* five times. *Developer options*
   appears at the bottom of Settings.
2. *Developer options*: turn on *ADB debugging*, then *Wireless debugging*.
3. In *Wireless debugging*, tap *Pair new device*. It shows a code and an address with a port. On the PC:
   ```powershell
   & "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" pair <address:pairing-port> <code>
   ```
4. Go back one screen: the *Wireless debugging* page shows the address with **another** port. Connect to that one:
   ```powershell
   & "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" connect <address:port>
   ```
5. Build and install (refuses anything that is not a watch):
   ```powershell
   ./watch/build.ps1 -Device <address:port>
   ```
6. Install the phone app that has the watch link, **in place** (never uninstall: that wipes the local data):
   ```powershell
   & "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" -s <phone> install -r app\build\app\outputs\flutter-apk\app-release.apk
   ```
7. Start a workout on the phone. W-fit opens on the watch; it asks once for notifications (the shortcut on the watch
   face) and heart rate. Both are optional.
8. Turn *Wireless debugging* off again: it uses battery.

## Trying it without a watch
On a Wear emulator the debug build has a receiver that plays the phone's part: see `DebugReceiver.kt`. The link itself
can only be tested with a real phone and watch.
