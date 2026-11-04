# Exercise demo photos — source & license

The `<exerciseId>_0.jpg` / `<exerciseId>_1.jpg` frames (start / end position) in this folder come from
**Free Exercise DB** by yuhonas and contributors — https://github.com/yuhonas/free-exercise-db
(itself based on [wrkout/exercises.json](https://github.com/wrkout/exercises.json)).

- License: **The Unlicense** — "This is free and unencumbered software released into the public domain."
  (https://unlicense.org, see the repository's `LICENSE.md`; the README describes the data as an
  "Open Public Domain Exercise Dataset").
- Pinned revision: `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`.
- Changes: resized to max 480 px wide, re-encoded as JPEG (quality 74), metadata stripped, renamed to W-fit exercise ids.

Attribution is not legally required for public-domain material, but we credit the project anyway.

`index.json` lists which catalog exercise maps to which source exercise. Regenerate everything with
`node app/tool/fetch_exercise_media.mjs` (see the header of that script). Exercises without a convincing match are
intentionally absent; the app falls back to the equipment illustration.
