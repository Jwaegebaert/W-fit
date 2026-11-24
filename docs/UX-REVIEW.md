# W-fit UI/UX review

23 November 2026, at commit `1cabacc` plus the uncommitted health changes. Analysis only: no app code was changed.

Paths are relative to `app/lib/features/` unless they start with `widgets/`, `core/`, `domain/` or `services/`.
**[seen]** = visible in a rendered screen or confirmed by a probe test. **[code]** = read in the code only.

---

## 1. Summary

The app has the right information. It feels bloated because **the same fact is shown several times at the same
weight**, because **explanations sit permanently on the page**, and because **the thing you do 29 times per workout
(tick a set) looks weaker than the thing you do once (Finish)**. Some parts also feel unfinished because they are
small bugs, not design choices.

### Top problems

| # | Problem | Why it matters in the gym |
|---|---|---|
| 1 | **Weight does not carry to the next sets, and an empty weight is logged as nothing.** Type 40 kg in set 1 of a first-time exercise, tick set 2: set 2 is saved without weight. Change set 2 to 30 kg: set 3 stays 27.5. [seen] | Wrong history, volume, PRs and advice. Also the most typing in the app. |
| 2 | **After you open one card by hand, cards stop opening by themselves** for the rest of the workout. [seen] | In a busy gym you go out of order, so you pay an extra tap and scroll per exercise. |
| 3 | **One card shows the rep target four ways**: `3 × 8–12` (header), `Aim 11 reps` (chip), `8-12` (field). Ticking logs `11`, a number the field never showed. [seen] | You cannot tell what a tick will save. |
| 4 | **"Not in my gym" selects all equipment of the exercise** (barbell *and* flat bench), and "Prefer another" silently marks the exercise as disliked. [seen/code] | One hurried tap changes all future plans. |
| 5 | **The workout card is crowded.** Four information layers before the first set. On a small phone with large text and the rest timer running, a bar exercise shows **no set row at all**. [seen] | Scrolling mid-set. |
| 6 | **Hierarchy is upside down**: Finish is the biggest, brightest button from second one; the set tick is grey on grey (1.16:1 against the card). [seen] | The eye goes to the wrong place; Finish is easy to hit and does not warn about open sets. |
| 7 | **The plan screen hides the plan.** With a coach plan the first exercise starts below the fold; on a small phone after about two screens. [seen] | You open it to see the exercises. |
| 8 | **Settings are spread over 8 screens with two ways of saving**, the same item is reachable from 3–5 places under different names, and five screens open with a permanent text block of 27–67 words. [seen] | Hard to remember where things live; feels heavy. |
| 9 | **Dark mode is unreadable in the two main coloured cards**: white on the Today card is 1.8–2.4:1, on the Coach header 1.7:1 (needs 4.5:1). Amber labels in light mode are 1.9:1. [seen, calculated] | Not readable at arm's length. |
| 10 | **Page titles are 14 px, smaller than the section titles below them (16 px)**, because the theme loses the font size. [seen] | This alone makes every page look unstructured. |

### What already works and should stay

Start is one tap from opening the app. Rest starts by itself. A planned set is one tap. Swapping a busy machine is two
taps. Exercise detail with photos is good. Last / Today / Aim is the right information. Everything works offline. No
layout overflows were found on either phone size.

### Recommended order

1. **Repairs** (bugs and contrast, little taste involved) → 2. **Workout screen** → 3. **Today and Plan** →
4. **Settings and wording** → 5. **Progress, Coach, Balance, colours**. Your choices are in section 6. Each phase can ship on its own (section 5).

If only one thing is done: phase 1. It removes the wrong data and most of the "not properly in place" feeling.

---

## 2. Across screens

### 2.1 Workout flow, taps counted

Default rule plan, 14 exercises and 29 sets (4 warm-up, 5 main, 2 core, 3 cool-down). [seen]

| Step | Taps now | Comment |
|---|---|---|
| Open app → workout running | 1 | Good. Via the plan: 2 |
| Tick 29 sets with the suggested values | 29 | 12 of them are warm-up/core/cool-down sets worth grouping |
| Finish → Save → Done | 3 | Two surfaces in a row (sheet, then dialog); Done then returns to Today |
| **Minimum** | **33** | Nothing changed, done in order |
| Out of order | + 1 and a scroll per remaining exercise | Problem 2 |
| Change 27.5 → 30 kg for 3 sets | about 21 | Tap, delete 4 characters, type 2, three times: no select-on-tap, no +/−, no carry-over |
| New exercise, 4 sets | 4 fields + about 8 keys + 4 ticks | 1 field + 2 keys + 4 ticks with carry-over |
| Report pain mid-set | 4 + scroll | First two taps are in the top right corner, out of thumb reach on an S25 Ultra |
| Swap, machine busy | 2 | Good |

### 2.2 The same thing in several places

| Thing | Where | Suggestion |
|---|---|---|
| Report an issue | plan menu, plan button, every plan row, session menu, Coach ("Report pain / tell your coach") | One name; session card, plan row, Coach |
| Exercise library | Today, Coach ("Exercise preferences"), Settings ("Exercise preferences") | One entry, called Exercises |
| Gym equipment | Settings, Coach tools, exercise detail, swap, report | Settings + the contextual ones |
| Body weight | Today tile, Progress icon, Progress chart | Progress only |
| Muscle balance card | Today and Progress, identical | Progress; Today at most one line |
| Streak, workout count | Today, Progress (and the count again in History) | Progress |
| Sync | Today icon, Settings "Sync now", pull to refresh | Icon only when there is a problem |
| AI usage | Coach footer, Backend connection | Backend connection |
| Bar rule ("log plates only") | card header, chip, bar line, column title, exercise detail, equipment screen | Column title + one line the first time |
| Injuries | Profile free text, Active limitations, report sheet, check-in card | One "Injuries" place |

**"Focus" means four things**: Muscle focus (setting), Next focus (Balance, calculated), Next focus (Coach, AI) and
focus pills in the plan. In the rendered Balance screen the calculated and AI answers disagree inside one card (lats,
upper back and rear delts against quads and side delts). The AI sample text was mine, but nothing in the code keeps
the two consistent (`balance/balance_screen.dart:91-108`). Suggestion: "Behind" for the calculated one, "Coach says" for
the AI one, "Muscle focus" only for the setting.

**The coach has many names**: AI coach, Coach, your coach, training coach, Smart plan, smart suggestions, on-device
insights, equivalent exercises, rebuild plan. Suggestion: "Coach" when AI wrote it, nothing at all otherwise.

### 2.3 Permanent explanations

| Screen | Words | Where |
|---|---|---|
| Muscle focus | 67 | `settings/muscle_focus_screen.dart:52-64` |
| Samsung Health, top + bottom | 48 + 38, plus long row subtitles | `settings/health_screen.dart:126-137, 217-222` |
| Equipment, plus bar weights and presets | 31 + 16 + presets | `settings/equipment_screen.dart:138-148` |
| Send workouts | 27 | `settings/health_send_screen.dart:99-109` |
| Exercise detail, load note | 10–20 | `exercises/exercise_detail_screen.dart:20-35` |

They all use the same tinted card as the coach note (`secondaryContainer`), so a manual and a coach message look equal.
Suggestion: one short line under the title, details behind a help icon; keep the tinted card for the coach only.

### 2.4 Colour

`core/theme.dart:6` promises teal plus "one warm gold accent". In use: teal, gold (coach badge, each side, body weight,
resume card, check-in, target line), three ambers (stars, flags, under target, light bulbs), orange (streak), coral
(work timer), purple (above target), red/blue/green (day type) and orange/purple/blue (section). 42 lines in
`features/` and `widgets/` use a hard-coded colour. Amber means "too little", "record", "advice", "rating" and "focus".

Suggestion, three meanings only: **teal** = action and done; **gold** = the coach and records; **red/orange** = attention
(pain, behind target, destructive). Day type keeps its icon; its colour becomes a small accent (section 6). Sections lose theirs.

### 2.5 Type, spacing, components

- App bar titles have no font size: `titleTextStyle` is built from a text theme that has no sizes yet
  (`core/theme.dart:93`), so they fall back to 14 px. Bottom tab labels have the same cause: 14 instead of 12 (`:129`).
- The first section title adds 20 px above itself (`widgets/common.dart:10`), leaving an empty band under the app bar in
  History and Settings. Balance already overrides this by hand.
- Card against page background is 1.05:1 in light mode, so cards hardly separate from the page and need their padding
  to be seen. A slightly stronger card, or no card for plain lists, would be calmer.
- `StatTile` rows (`widgets/common.dart:29`) spend about 100 px on one number, and leave an empty bottom at large text.
- `FittedBox` inside segments shrinks only the longest label, so "Normal" is visibly smaller than "Less"/"More" at large
  text (`settings/muscle_focus_screen.dart:121`; also in Profile).
- Selected choice chips with an icon draw a check over the icon, giving a dark blob
  (`widgets/report_issue_sheet.dart:199-207`; needs `showCheckmark: false`).
- Destructive confirmations (Discard, Delete) use the same teal filled button as Save (`workout/session_screen.dart:191`,
  `history/session_detail_screen.dart:42`).
- Two save models: Profile needs Save and loses changes on back without asking (`settings/profile_screen.dart:95-98`);
  Focus, Equipment and Health save at once.

### 2.6 Accessibility

- Contrast: section 1, row 9. Also the coral timer 2.3:1, light-mode hero subtitle 2.7–3.2:1, unticked tick button 1.16:1
  against its card. "Start workout" on Today fails Flutter's automatic contrast check in light and dark mode. [seen]
- No spoken label on the set tick and the API key eye (`workout/session_screen.dart:633, 673`,
  `settings/connection_screen.dart:99`). [seen]
- Touch targets under 48 px: the coach line (34 px high) and the muscle focus segments (40 px). [seen]
- Text scaling: no overflow at 1.3×. The costs are height (session list 4.5 screens, plan 5.7) and shrunken labels.

### 2.7 Phone and watch

Not a watch design; only where the two touch.

- **Set rows do not refresh from the database.** The weight and reps fields are filled once
  (`workout/session_screen.dart:342-355`). A set logged on the watch shows a tick on the phone but keeps the old numbers,
  and a later edit on the phone saves those old numbers over the watch's. [code] Fix before both can log.
- **"Current exercise" exists only in the phone's UI state** (`:40-41, 83`), and **the rest timer only in phone memory**
  (`workout/workout_timer.dart`). Problem 2 must be fixed in a place the watch can share, not just in this widget.
- The rest timer ends with a vibration only. There is no notification plugin, so with the screen off or another app open
  it probably alerts nobody. [code, not tested on a phone] If the watch takes this over, the phone bar can get smaller.
- "One aim per set" (problem 3) is what the watch needs too: fix the rule once, in the domain layer.
- "Finish" and the rating sheet: decide which device asks.

---

## 3. Screens

Each screen: its job, what is wrong, what to do. Page length is in viewports on a normal phone (393×851).

### 3.1 Today — `dashboard/dashboard_screen.dart` (1.8 screens)

**Job:** start or resume today's workout.

- Hero `:197-262`: two pills, icon, title, muscles, time, count, chips, two buttons. Title and muscles overlap; "Smart
  plan" informs nobody; chips of 3 exercises are a partial plan next to a View plan button. On a small phone with a
  longer coach title, Start is cut off by the tab bar [seen]; the layout test only checks the short rule titles.
- Dark mode contrast (`core/theme.dart:184-188` gives light tones, white text sits on top, `:200-216`).
- On a rest day the card shows a future date with the same "Start workout" and starts it at once. Say "Next: Wednesday"
  and "Start today anyway".
- Resume card **and** a Resume button in the hero at the same time; two entries for one action (`:68-69, 242-249`).
- Check-in cards have different widths and are centred, because the column does not stretch (`:146`) [seen]. The second
  one is cut off by the tab bar.
- Week dots and "1 / 3 sessions" and a progress bar say the same; a streak of 0 is noise (decided: keep the streak, see 6).
- "Coming up" repeats fixed rotation facts; not tappable, though it looks like a list.
- Quick actions: Body, Exercises, Workouts. Only a detour to other tabs; "226 moves" is trivia.
- Error text shows the raw exception (`:124`); the loading state keeps a 220 px box. [code]
- A failed sync shows a red icon without a text; the reason needs a long press.

**Do:** hero = date, title, time and count, Start, and the whole card opens the plan. Below: check-in as one line, week
dots, nothing else. Remove Quick actions, Coming up and the Balance card.

### 3.2 Plan — `workout/plan_screen.dart` (2.6; small phone 5.7)

**Job:** see and adjust today's exercises.

- Order is pills, coach note, up to 6 reasons, changes, report button, and then exercises (`:125-162`). [seen]
- The first reason repeats the program pill word for word (`domain/rule_engine.dart:1413`); focus pills repeat
  other reasons; the date and source repeat Today.
- The rule plan's coach note is the same sentence every workout (`domain/rule_engine.dart:1404-1405`).
- A change line can read "Machine Chest Press → Machine Chest Press"; this came from my test data, but nothing filters
  equal names. [code]
- Rows: two trailing buttons take 96 px, so targets and notes wrap to 4–6 short lines (`:243-252`).
- Menu: **Rebuild** and **Switch to … day** replace the plan, including coach changes, without asking (`:101-117`).
  "Remove from today" has no undo (`:186`). [code]
- "Report an issue" three times on one screen.
- With a workout running, Start still says "Start workout" but opens the running one (`workout/workout_actions.dart:12`).
- The app bar title is cut off at large text; the full title appears nowhere else.
- The busy overlay has no text; "Ask AI coach" can take up to about two minutes (`:196-200`). [code]

**Do:** one line (date · min · program), one coach line that expands to the reasons, then the list. Row: name + one
target line, tap = detail, long press or ⋮ = swap/remove/report. Confirm or undo for Rebuild and Switch.

### 3.3 Live session — `workout/session_screen.dart`, `workout/coach_strip.dart` (2.4–3.0; small 4.5–5.5)

**Job:** do the current set, log it, rest.

Flow
- Problem 1: `:342-355` fills a row only when it is created; `:364-382` saves an empty weight as null.
- Problem 2: `_expandedKey` is never cleared after a tap (`:83, 108-115`), only after a swap (`:129`).
- In automatic mode the card closes the moment the last set is ticked, so its reps can't be corrected without reopening,
  the Add set button disappears, and the list jumps under your thumb. [code]
- Problem 3: header `:471`, chip `coach_strip.dart:140-148`, hint `:595-597`, saved value `:357, 366-368`. The chips also
  mix sources: Today comes from the plan, Aim from the progression rule, so a heavier weight can ask for more reps than
  last time. [seen with a coach weight; the advice line then says "Same weight"]
- Finish works at 0 of 29 sets without a warning and saves 4 stars and effort 7 if untouched (`:807-808`); these feed
  the statistics and the coach. [seen]
- Finish sheet, then summary dialog, then Today: the result is never shown in place.
- Swapping an exercise with logged sets hides those sets while they still count in "x / y sets" (`:71, 104`). [code]
- Skipping a work timer does not log the set (`workout_timer.dart:62-66`); unclear from the UI. [code]

Look
- Layers above the first set: header, chips (wrap to two rows), coach line, bar line, column titles.
- Facts repeated on one bar card: "(+20 bar)" in the header, "(+20 bar)" in the chip, "Log plates only · Barbell bar 20
  kg is added in your stats", "Plates kg". Wording: "Barbell bar".
- Timed per-side card: "1 × 30s / side", "Each set: 30s per side, the timer runs both.", "30s".
- "0/3 done" repeats the ticks; "3 / 20 sets" repeats the progress line.
- All 14 cards carry info and swap icons: 28 icon buttons, of which 2 matter.
- The coach line is cut after about 35 characters, and the first-time hint is cut before the useful part.
- Warm-up, core and cool-down look as important as the main work: 9 of 14 cards, 12 of 29 ticks.
- Timed rows: the useful button (Start) is a small text button next to a large grey tick.
- The grey tick already shows a check mark, so "not done" looks like "done but faded".
- Work timer label is cut before the side: "Chest Doorway Stretch ·…" (`:422-423, 768`). The side is the one thing you
  need. The meditating figure as rest icon is odd; fine to drop.
- While typing, the timer and Finish sit behind the keyboard.
- Menu: Report sits above Discard, both in the top right.
- "Free workout: No plan attached" is a dead end with only Finish. [seen; probably unreachable in normal use]
- Loading: a spinner without an app bar or back button if the session does not exist (`:58-60`). [code]

**Do:** see 4.1.

### 3.4 Swap sheet — `workout/swap_sheet.dart`

**Job:** pick a replacement in two taps.

- Reasons, explanation, equipment chips, note and AI button come before the list (`:182-254`). With AI connected, a small
  phone shows no alternative without scrolling [seen].
- Problem 4: `_selectedEquipment = _original.equipment` (`:94`) applies to every reason; `:152-156` stores a dislike.
- The empty text blames equipment, also when an active injury excludes the options (`:263`). [seen: shoulder pain active,
  "Prefer another", no equipment excluded]
- "horizontal push" is internal vocabulary (`:179`). The swap icon on every row repeats the sheet title.
- The AI error is good (clear, keeps the list), but red for something harmless.

**Do:** list first. Reason chips on one line above it, default Occupied. "Not in my gym" asks which item and preselects
none. "Prefer another" does nothing lasting; "Never suggest again" is the explicit option. AI and note at the bottom.

### 3.5 Report sheet — `widgets/report_issue_sheet.dart`

**Job:** say what hurts in a few seconds.

- Opened from Coach it stays under the tab bar, which stays bright and takes about 120 px (opens in the tab's own
  navigator, `widgets/common.dart:202-203`; needs the root navigator). [seen]
- Up to 7 reasons, of which "Equipment unavailable" and "Doesn't feel right" repeat the swap sheet.
- "Other note" needs text to save, but the field says optional (`:96, 265`); Save is just disabled. [code]
- Asking the coach for something ("go easy on my shoulders") is hidden as Other note inside a problem report, while
  Muscle focus tells you to ask the coach there.
- Only one body region per report.
- The severe warning is well done. The outcome screen is good; "Save to settings" is clear. "Muscle focus: Front delts:
  less, go light" has two colons.

**Do:** split by intent: Pain (region, severity, optional note) and Tell the coach (free text). Equipment and preference
stay in swap.

### 3.6 History — `history/history_screen.dart` (1.0)

**Job:** find a past workout.

- Clean. Minor: empty band on top; "5737.5 kg" without thousands separator or rounding (`:60`); accidental workouts
  ("0 min · 0 sets · 0 kg") look the same as real ones; the star is mostly the default 4.
- Empty state is fine; a button to Today would help.

**Do:** round volume, fold tiny sessions, move into Progress (decided, section 6).

### 3.7 Session detail — `history/session_detail_screen.dart` (2.7)

**Job:** see what I did.

- One card per exercise with chips per set: 14 cards, 9 of them warm-up, core or cool-down. "Warm-up" is repeated on
  every card instead of one heading (`:97-133`).
- Up to 5 stat tiles plus a rating card before the first exercise.
- A wrong set can't be corrected; only deleting the whole workout is possible. [code] Given problem 1 this matters.
- "Workout" as app bar title, then the real title below. Delete is the only action, top right, no undo, and its dialog
  has no text (`:38-45`).

**Do:** title in the app bar, one summary line, main work as a compact list, the rest collapsed, edit sets.

### 3.8 Progress — `stats/stats_screen.dart` (2.7)

**Job:** am I getting stronger, am I consistent.

- Four tiles first; "exercises tracked" with a trophy and "workouts total" are filler (`:60-72`).
- Both weekly charts include the running week, so they usually end in a drop that is not real.
- "Personal records" is sorted by estimated max, so big machines always win, and includes warm-ups ("World's Greatest
  Stretch, Best 6 reps") (`:50-51, 94`). [seen] It shows 12, no "all", and no date, so it is a list of bests, not news.
- The records are the useful part and start on screen 2.

**Do:** lifts with trend arrows first, then consistency, balance, body weight. Hide warm-ups; mark the running week.

### 3.9 Exercise progress — `stats/exercise_progress_screen.dart`

**Job:** is this lift moving.

- Three charts that mostly say the same; tiles repeat the first chart.
- "since first session %" is meaningless with 1–2 sessions.
- Empty state is fine.

**Do:** one chart with a switch (max / top set), then the sessions.

### 3.10 Coach — `coach/coach_screen.dart` (offline 1.6; with AI about 2)

**Job:** what should I change, and tell the coach something.

- The gradient header carries no information except a timestamp (`:109-134`); unreadable in dark mode.
- "Plan / regenerate next workout" explains where a menu is, and only switches to Today (`:195-201`).
- Equipment and Exercise preferences are settings (`:202-213`).
- "312k of 3000k tokens" is developer information (`:216-225`).
- Summary, Highlights, Recommendations and Next focus are four cards of prose; Next focus, the actionable one, is last.
- The report button wraps to two left-aligned lines at large text.
- Offline notice and fallback are good.

**Do:** Next focus on top, active injuries, Recommendations, Summary collapsed; two buttons: Report pain, Ask coach.

### 3.11 Balance — `balance/balance_screen.dart` (2.4)

**Job:** which muscles are behind.

- **Distribution bar is invisible**: coloured boxes without a child get height 0 (`:297-301`). [seen: legend, no bar]
- **Colours contradict numbers**: "Chest 3 · 6–12" is purple (above target), because the status uses the higher of this
  and last week (`domain/training_load.dart:332-335`) while bar and number show this week. The strip on Today colours by
  this week, so the same muscle can have two colours. [seen]
- Five sections; "Recently trained" is 19 pills with no order you can use; heatmap text is 19 rows high.
- "not trained recently" repeated on each line.

**Do:** fix both bugs; keep Behind + This week; heatmap and the rest collapsed.

### 3.12 Body — `body/body_screen.dart` (1.3)

**Job:** log weight.

- Tiles "entries: 3" and "change" without a period (`:44-58`). Body fat is stored but never charted.
- The Log button covers the weight of the entry behind it while scrolling. [seen]
- Deleting an entry is immediate, no undo (`:189-197`).
- Form is good; measurements collapsed is right.

**Do:** current weight + 4-week change in the chart title, drop the tiles, undo on delete.

### 3.13 Library — `exercises/library_screen.dart`

**Job:** find an exercise.

- Starts with warm-ups in catalogue order; no filter by muscle or equipment; Warm-up and Mobility chips are off screen.
- "Available" (on/off) looks the same as the categories (pick one).
- Badminton racket icon unexplained and on many rows; the search hint advertises "badminton" and is cut off.
- Settings calls this "Exercise preferences", but a preference can only be set at the bottom of each detail page.

**Do:** default to Strength, A–Z, muscle filter; swipe or long press to like/ban; filter "my likes and bans".

### 3.14 Exercise detail — `exercises/exercise_detail_screen.dart` (2.1)

**Job:** how do I do it (often mid-workout).

- App bar shows the category, the name comes below the photo.
- The facts strip shows catalogue sets, reps and rest (`:157-171`), which can differ from today's plan. Mid-workout that
  is a second, wrong target. [code]
- The preference picker is four icons without labels, at the very bottom (`:402-413`).
- "No demo photo yet — use Watch a demo" points to a button about two screens down that needs internet.
- Steps and Form check are good and short. Badminton card is fine but gold like a coach message.

**Do:** name in the app bar, preferences as an app bar icon with labelled choices, facts only outside a workout,
Watch a demo next to the photo.

### 3.15 Settings — `settings/settings_screen.dart` (1.0)

**Job:** find a setting.

- "Training" contains Samsung Health and the library; rest, cool-down, core and length are inside "Profile & schedule".
- "Sync now" is an action between navigation rows. About text repeats the connection text.

**Do:** structure in 4.4.

### 3.16 Profile & schedule — `settings/profile_screen.dart` (1.4)

- Name, schedule, training rules and body facts in one form; Save twice; back loses changes silently.
- Goals field sits directly against the "About you" heading. The injuries label is cut off at large text.
- Seven helper texts; "Recommended: 3 non-consecutive days" is always there, also when you follow it.

**Do:** split "Schedule & session" from "About you", save at once.

### 3.17 Equipment — `settings/equipment_screen.dart` (5.6 screens, the longest page)

- Presets first, although they are used once; buttons have different widths; then text, bar weights, about 40 switches
  each with a two-line description cut mid-sentence. [seen]
- Bar weights hide between presets and equipment; "Smith machine: Not set" does not stand out, though it makes your Smith
  volume wrong.
- No picture or tap for detail here, while exercise detail has a nice equipment sheet.

**Do:** groups collapsed with "6 of 8 available", names only, tap = sheet (with the bar weight inside it), presets in the
menu.

Equipment sheet `widgets/equipment_sheet.dart`: good. Bar weight dialog `settings/equipment_screen.dart:9-53`: good
wording; its text controller is disposed while the dialog is still closing (`:49`), which crashes debug tests and
deserves a fix. [seen in a probe; release builds skip that check]

### 3.18 Muscle focus — `settings/muscle_focus_screen.dart` (2.6)

- 67 words, then 19 rows × 4 buttons, all "Normal" in the usual case.
- Less/Normal/More and Go light are two ideas side by side; the 40 px segments are small.

**Do:** list of muscles with the current value as text, only changed ones highlighted on top; tap opens a small sheet
with four labelled choices.

### 3.19 Samsung Health and Send workouts — `settings/health_screen.dart`, `settings/health_send_screen.dart`

- Connect state, explanation (48 words), three "what is shared" paragraphs, check, send, and instructions (38 words).
- "Check recent workouts now" and "Send workouts" overlap; the second screen then explains again.
- A one-time set-up and a trouble-shooting tool are always shown, also when everything works.
- Not available: the whole explanation still shows above "Not available". [seen]
- Send: statuses are clear; "Clear" next to "Select not sent (4)" is fine. Results after sending are good.
- Uncommitted work touches both files: change them only after that is committed.

**Do:** one status line ("Connected · last workout sent 18:32"), calories switch, then "Problems?" which opens the
instructions and the send list.

### 3.20 Connection — `settings/connection_screen.dart`

- Good and rarely needed. "Disconnected" is shown in red because colour depends on the text starting with "Conn"
  (`:122`). "Save & connect" wraps left-aligned at large text. "Test" next to "Save & connect" is not needed: saving tests.

---

## 4. Before and after, the biggest changes

### 4.1 Exercise card

```
NOW                                        PROPOSED
[icon] Barbell Bench Press     (i) (swap)  Barbell Bench Press            (i) (swap)
3 × 6–10 · 40 kg plates (+20 bar) · 0/3    Last 37.5 × 10, 9, 8 · aim 8       Coach v
[Last …] [Today 40 kg plates (+20 bar)]    
[Aim 6–10 reps]                            1   [ − 40 + ] plates  [ − 8 + ]   ( o )
Coach  Plates only; lighter than…    v     2   [ − 40 + ]         [ − 8 + ]   ( o )
— Log plates only · Barbell bar 20 kg      3   [ − 40 + ]         [ − 8 + ]   ( o )
  is added in your stats            edit   + set
Set     Plates kg        Reps
1       40               6-10        (v)
```

- Same facts, one line instead of four layers. The field shows exactly what the tick saves.
- Weight changes flow to the following unticked sets. Tapping a number selects it and opens the keypad; − and + use the
  exercise's own step. Only the active row needs the − and +; done rows become plain text.
- Info and swap only on the open card. Collapsed cards: name and target, one line.
- Unticked = empty outlined circle, ticked = filled teal.
- Finishing the last set keeps the card open for correction and shows "Next: Machine Shoulder Press" in the bottom bar;
  tapping it, or starting any set there, moves on. The bottom bar is the place your thumb already is.
- Finish is a quiet text button until all main sets are done, then becomes the filled one. If sets are open it says so.

### 4.2 Warm-up and cool-down

Now: 7 cards with their own sets, icons and timers. Proposed: one card per section with a check list; tick a line when
done, tap it for the timer or details, "All done" ticks the section. Fewer cards to scroll past (14 → about 9).

### 4.3 Today and Plan

Now: hero with 12 elements and five sections below it; Plan shows reasoning first. Proposed: Today = workout card +
check-ins + week dots. Plan = list first, "Why this plan" as one expandable line.

### 4.4 Settings

```
NOW                                     PROPOSED (everything saves at once)
Training                                Training
  Profile & schedule (Save button)        Schedule & session   days, length, core, rest, cool-down
  Gym equipment                           Muscle focus
  Muscle focus                            Injuries             active ones + report
  Samsung Health                          Exercises            likes and bans
  Exercise preferences                  Gym
Cloud & AI                                Equipment & bar weights
  Backend connection                    Connections
  Sync now                                Samsung Health
About                                     Cloud & coach        status, sync, AI usage
                                        About you              name, goals, height, birth year, version
```

### 4.5 Finish

Now: sheet (stars, slider, notes, Save) → dialog (3 numbers, records, Done) → Today. Proposed: one full sheet with the
result and records on top, effort **unset** until touched, optional note, one Save. (Decided: effort only, no volume.) Two taps instead of three.

---

## 5. Prioritised list

**Status, 24 November 2026:** phase 1 is committed (e26a47d). Phases 2 to 5 are built in the main checkout, uncommitted
and not installed on the phone. The sections above describe the app before phase 1. Not done, or done differently:

- P4.5 (Samsung Health screens): the other session's health changes are still uncommitted, so those files were left alone.
- P1.6 and the slimmer timer bar of P2.4: the watch branch rewrote that code; decide there.
- P2.1: the next card opens by itself after the last set (built in phase 1) instead of a "Next" button in the bottom bar;
  − and + are below the fields of the set to do now, because they do not fit next to them on a small phone.
- P2.3: warm-up and cool-down lines log all sets of the exercise with the planned reps or time and no longer count in
  "x / y sets".
- P2.5: records are shown before saving; warm-up and cool-down sets never count as records.
- P5.1b: volume is gone from every screen; the coach brief sent to the AI still has it.
- P5.5: warm-up, core and cool-down lost their colours; push, pull and legs keep theirs on small icons and one chart.

Impact on training: H/M/L. Effort: XS under an hour of work, S, M, L. Tokens are a rough estimate of everything one Claude
session processes (reading, edits, tests, screenshots), ±50 %. Items in one phase share reading, so a phase costs less
than its sum.

| ID | Change | Impact | Effort | Tokens |
|---|---|---|---|---|
| **Phase 1: Repairs** | | | | **130–200k** |
| P1.1 | Weight flows to later sets; a weighted set can't be ticked without weight | H | S | 35k |
| P1.2 | Opening cards by hand no longer stops auto-advance; next card scrolls into view | H | S | 30k |
| P1.3 | One aim per set, from one rule; field shows it, tick saves it | H | S | 35k |
| P1.4 | Swap: no preselected "not in my gym", no silent dislike, honest empty text | H | S | 30k |
| P1.5 | Finish warns about open sets; effort starts unset, stars are no longer asked | H | S | 30k |
| P1.6 | Set rows refresh from the database (needed for the watch) | H with watch | S | 30k |
| P1.7 | Dark contrast first: teal Today card, plain Coach header; then amber labels, tick button, coral timer | H | S | 30k |
| P1.8 | Title and tab font sizes, first-section gap, check-in width, report sheet over tab bar, chip blob, timer side first, disconnect colour, spoken labels, dialog controller | M | S | 35k |
| P1.9 | Balance: distribution bar, one colour rule | M | XS | 15k |
| P1.10 | Confirm or undo: rebuild, switch day, remove, delete body entry; red destructive buttons | M | S | 30k |
| **Phase 2: Workout screen** | | | | **200–300k** |
| P2.1 | New exercise card (4.1) incl. compact coach line and bar rule | H | L | 110k |
| P2.2 | − / + and select-on-tap | H | M | 45k |
| P2.3 | Warm-up and cool-down check lists (4.2) | H | M | 55k |
| P2.4 | Bottom bar: next exercise, quiet Finish, slim timer | M | M | 45k |
| P2.5 | Finish and summary in one sheet (4.5): effort, note, records; no volume | M | S | 35k |
| P2.6 | Swap sheet list-first; report split in Pain / Tell the coach | M | M | 55k |
| **Phase 3: Today and Plan** | | | | **100–160k** |
| P3.1 | Today: smaller hero, rest-day wording, remove three sections | M | M | 50k |
| P3.2 | Plan: list first, reasons collapsed, one report entry, wider rows | H | M | 55k |
| P3.3 | Drop the fixed coach sentence and the duplicate reason from rule plans | M | XS | 15k |
| **Phase 4: Settings and wording** | | | | **140–220k** |
| P4.1 | New settings structure, save at once | M | M | 60k |
| P4.2 | Explanations → one line + help; tinted card only for the coach | M | S | 35k |
| P4.3 | Equipment collapsed, bar weight in the sheet | M | M | 45k |
| P4.4 | Muscle focus as list + sheet | M | M | 45k |
| P4.5 | Samsung Health to one status + "Problems?" (after the uncommitted work lands) | M | S | 35k |
| P4.6 | One name per thing (report, coach, focus, exercises) | M | S | 25k |
| **Phase 5: Progress, Coach, colours** | | | | **200–290k** |
| P5.1 | Progress: lifts first, no warm-ups, running week marked, fewer tiles | M | M | 50k |
| P5.1a | Three tabs: History becomes part of Progress (recent workouts + all) | M | M | 45k |
| P5.1b | Remove total volume everywhere; streak and workout count once, in Progress | M | S | 25k |
| P5.2 | Coach: focus first, no header, no settings links | M | S | 35k |
| P5.3 | Session detail compact + edit a logged set | M | M | 55k |
| P5.4 | Balance shortened; exercise progress with one chart | L | S | 35k |
| P5.5 | Colour roles (2.4) | M | M | 45k |
| P5.6 | Library filters and quick like/ban; exercise detail header | L | M | 45k |

Phase 2 must wait for, or be agreed with, the watch session on P1.2, P1.3 and P1.6. The layout and screenshot tests find
widgets by their text ("Start workout", "View plan", "Swap exercise", "Report pain / tell your coach"), so renames need
those updated too.

---

## 6. Decisions (23 November 2026)

| Question | Decision | Effect on the plan |
|---|---|---|
| Theme in the gym | **Dark** | P1.7 becomes the first visual fix; every new design is judged in dark first. Light must stay correct. |
| Reps | **One tick saves the aim**; − / + to correct | P1.3 and P2.2 as proposed in 4.1. |
| Warm-up and cool-down | **Checklist per section** | P2.3 as proposed in 4.2. |
| Tabs | **Today / Progress / Coach** | New item P5.1a: History moves into Progress. |
| Coach tab | **Only what to do next** | P5.2: focus and recommendations on top, the rest behind one line. |
| "Why this plan" | **One expandable line** | P3.2 as proposed. |
| After a workout | **Effort only**, unset until touched, optional note | P1.5 and P2.5. Stars are no longer asked or shown; old ratings stay stored. See below. |
| Rest end | **Leave it to the watch** | No notification or sound work on the phone. The timer keeps its vibration. |
| Day colours | **Small accents only** | Teal Today card (solves the dark contrast there as well), day colour on icons in lists. Part of P1.7. |
| Motivating numbers | **Week streak, number of workouts, records and trends** | Total volume in kg disappears from the summary, History, session detail, Progress and the offline coach text. Streak and count stay, once, in Progress. |

What follows from these, worth knowing:

- **Effort drives the program.** An average of 8.5 or more over three sessions starts an early deload
  (`domain/program.dart:282-286`), and the AI is told not to raise loads after high effort. Today every untouched sheet
  saves 7, so these signals are diluted. Unset until touched makes them honest.
- **Stars also have a job.** Two ratings of 2 or lower in a row start an early deload (`domain/program.dart:283-288`).
  Without stars that trigger ends; effort and regressing lifts remain. Skipping effort often means fewer early deloads.
- **Week streak stays**, so the remark in 3.1 is reduced to: show it only from 1 upwards, and only in one place.
- **Rest end depends on the watch app.** Until it ships, the phone still gives no alert with the screen off.

Still open, to decide when the phase starts: whether the estimated max (e1RM) is useful to you in records (phase 5), and
the wording of the one report button (phase 4).

---

## 7. What was looked at

- The existing screenshot harness (about 120 images: normal phone, small phone with 1.3× text, part dark).
- A temporary harness outside the repository for states the first one misses, in all three variants (187 images): coach
  plan with reasons and changes, check-ins, resume, plan and session menus, dialogs, open coach line, ticked sets, keyboard,
  bar / Smith / assisted / optional weight / per side / timed cards, work timer, records summary, session without plan, heart
  rate, AI insights, AI error in swap, all report variants and the outcome, equipment sheet and preset, all Samsung Health
  states, send results, empty search and progress, and dark versions of everything.
- Probe tests for logged weights, auto-advance, font sizes, page lengths, touch targets, labels and contrast.
- All screen, sheet, theme and shared widget code.

Not rendered, so **code only**: AI busy overlay, "Coach is preparing", sync spinner, plan error on Today, successful AI
swap list, full-screen photo, date picker, deload week, muscle focus with values, "access removed" in Health, AI usage
tiles, installing Health Connect. Coach texts and the contradicting focus were made-up samples.

Not checked at all: the real phone (sunlight, haptics, one-hand reach, screen off during rest), the actual AI's text
lengths, TalkBack in practice. The S25 Ultra is slightly wider than the 393 px used here, so it looks a little roomier.

Harness gaps worth adding later: dark mode beyond the first screens, a coach plan, long titles, a running workout, and
the equipment page end at large text (that image came out empty; a scroll artefact of the harness as far as I can tell).
