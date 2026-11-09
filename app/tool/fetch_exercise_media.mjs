// Regenerates the built-in exercise demo frames in app/assets/exercises/.
//
// Source: free-exercise-db (https://github.com/yuhonas/free-exercise-db), The Unlicense (public domain).
// Each mapped exercise gets <exerciseId>_0.jpg (start) and <exerciseId>_1.jpg (end), max 480px wide,
// metadata stripped, plus app/assets/exercises/index.json.
//
// Run (from the repo root; sharp lives outside the repo):
//   mkdir %TEMP%\wfit-tools && cd %TEMP%\wfit-tools && npm init -y && npm i sharp
//   node app/tool/fetch_exercise_media.mjs            # uses %TEMP%\wfit-tools (override with WFIT_TOOLS=<dir>)
//
// The MAPPING table below is hand-reviewed: only add an entry after checking that the source photos show the
// same movement AND the same equipment type. Exercises without a good match are left out on purpose
// (the UI falls back to the equipment illustration).

import { createRequire } from 'node:module';
import { mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE_REPO = 'yuhonas/free-exercise-db';
const SOURCE_REF = 'f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5'; // pinned main @ 2026-09-27
const RAW = `https://raw.githubusercontent.com/${SOURCE_REPO}/${SOURCE_REF}`;
const MAX_WIDTH = 480;
const QUALITY = 74;

// exerciseId (catalog.json) -> free-exercise-db id
const MAPPING = {
  // warm-up
  'rowing-easy': 'Rowing_Stationary',
  'bike-easy': 'Bicycling_Stationary',
  'treadmill-walk-jog': 'Jogging_Treadmill',
  'elliptical-easy': 'Elliptical_Trainer',
  'jump-rope-easy': 'Rope_Jumping',
  'arm-circles': 'Arm_Circles',
  'band-pull-apart': 'Band_Pull_Apart',
  'band-external-rotation': 'External_Rotation_with_Band',
  'cat-cow': 'Cat_Stretch',
  'worlds-greatest-stretch': 'Worlds_Greatest_Stretch',
  'inchworm': 'Inchworm',
  'bodyweight-squat': 'Bodyweight_Squat',
  'glute-bridge': 'Butt_Lift_Bridge',
  'cable-external-rotation': 'External_Rotation_with_Cable',
  'standing-hip-circles': 'Standing_Hip_Circles',
  'leg-swings': 'Front_Leg_Raises',
  'standing-thoracic-rotation': 'Middle_Back_Stretch',
  'scapular-pull-up': 'Scapular_Pull-Up',
  'dynamic-chest-opener': 'Dynamic_Chest_Stretch',
  // push
  'smith-bench-press': 'Smith_Machine_Bench_Press',
  'cable-overhead-triceps-extension': 'Triceps_Overhead_Extension_with_Rope',
  'explosive-incline-push-up': 'Incline_Push-Up',
  'barbell-bench-press': 'Barbell_Bench_Press_-_Medium_Grip',
  'dumbbell-bench-press': 'Dumbbell_Bench_Press',
  'incline-dumbbell-press': 'Incline_Dumbbell_Press',
  'machine-chest-press': 'Leverage_Chest_Press',
  'smith-incline-press': 'Smith_Machine_Incline_Bench_Press',
  'push-up': 'Pushups',
  'seated-dumbbell-shoulder-press': 'Seated_Dumbbell_Press',
  'machine-shoulder-press': 'Machine_Shoulder_Military_Press',
  'dumbbell-lateral-raise': 'Side_Lateral_Raise',
  'cable-lateral-raise': 'Standing_Low-Pulley_Deltoid_Raise',
  'pec-deck-fly': 'Butterfly',
  'cable-chest-fly': 'Cable_Crossover',
  'cable-triceps-pushdown': 'Triceps_Pushdown',
  'overhead-dumbbell-triceps-extension': 'Standing_Dumbbell_Triceps_Extension',
  'bench-dip': 'Bench_Dips',
  'medicine-ball-chest-pass': 'Medicine_Ball_Chest_Pass',
  'machine-incline-chest-press': 'Leverage_Incline_Chest_Press',
  'machine-decline-chest-press': 'Leverage_Decline_Chest_Press',
  'dumbbell-chest-fly': 'Dumbbell_Flyes',
  'high-to-low-cable-fly': 'Cable_Crossover',
  'bar-dip': 'Dips_-_Triceps_Version',
  'incline-barbell-bench-press': 'Barbell_Incline_Bench_Press_-_Medium_Grip',
  'incline-push-up': 'Incline_Push-Up',
  'seated-arnold-press': 'Arnold_Dumbbell_Press',
  'standing-barbell-overhead-press': 'Standing_Military_Press',
  'smith-shoulder-press': 'Smith_Machine_Overhead_Shoulder_Press',
  'dumbbell-scaption-raise': 'Dumbbell_Scaption',
  'cable-upright-row': 'Upright_Cable_Row',
  'ez-bar-skull-crusher': 'EZ-Bar_Skullcrusher',
  'close-grip-bench-press': 'Close-Grip_Barbell_Bench_Press',
  'smith-close-grip-bench-press': 'Smith_Machine_Close-Grip_Bench_Press',
  'rope-triceps-pushdown': 'Triceps_Pushdown_-_Rope_Attachment',
  'single-arm-cable-pushdown': 'Cable_One_Arm_Tricep_Extension',
  'dumbbell-triceps-kickback': 'Tricep_Dumbbell_Kickback',
  // pull
  'lat-pulldown': 'Wide-Grip_Lat_Pulldown',
  'neutral-grip-lat-pulldown': 'V-Bar_Pulldown',
  'band-assisted-pull-up': 'Band_Assisted_Pull-Up',
  'seated-cable-row': 'Seated_Cable_Rows',
  'one-arm-dumbbell-row': 'One-Arm_Dumbbell_Row',
  'chest-supported-dumbbell-row': 'Dumbbell_Incline_Row',
  'barbell-row': 'Bent_Over_Barbell_Row',
  'inverted-row': 'Inverted_Row',
  'face-pull': 'Face_Pull',
  'reverse-dumbbell-fly': 'Seated_Bent-Over_Rear_Delt_Raise',
  'pec-deck-rear-delt': 'Reverse_Machine_Flyes',
  'straight-arm-pulldown': 'Straight-Arm_Pulldown',
  'dumbbell-biceps-curl': 'Dumbbell_Bicep_Curl',
  'hammer-curl': 'Hammer_Curls',
  'cable-biceps-curl': 'Standing_Biceps_Cable_Curl',
  'ez-bar-curl': 'EZ-Bar_Curl',
  'medicine-ball-slam': 'Overhead_Slam',
  'cable-woodchop': 'Standing_Cable_Wood_Chop',
  'underhand-lat-pulldown': 'Underhand_Cable_Pulldowns',
  'close-grip-lat-pulldown': 'Close-Grip_Front_Lat_Pulldown',
  'single-arm-lat-pulldown': 'One_Arm_Lat_Pulldown',
  'pull-up': 'Pullups',
  'chin-up': 'Chin-Up',
  'chest-supported-machine-row': 'Leverage_Iso_Row',
  't-bar-row': 'T-Bar_Row_with_Handle',
  'smith-bent-over-row': 'Smith_Machine_Bent_Over_Row',
  'bent-over-dumbbell-row': 'Bent_Over_Two-Dumbbell_Row',
  'dumbbell-shrug': 'Dumbbell_Shrug',
  'barbell-shrug': 'Barbell_Shrug',
  'smith-behind-back-shrug': 'Smith_Machine_Behind_the_Back_Shrug',
  'cable-shrug': 'Cable_Shrugs',
  'rear-delt-cable-fly': 'Cable_Rear_Delt_Fly',
  'chest-supported-rear-delt-raise': 'Dumbbell_Lying_Rear_Lateral_Raise',
  'ez-bar-preacher-curl': 'Preacher_Curl',
  'dumbbell-preacher-curl': 'One_Arm_Dumbbell_Preacher_Curl',
  'incline-dumbbell-curl': 'Incline_Dumbbell_Curl',
  'cable-rope-hammer-curl': 'Cable_Hammer_Curls_-_Rope_Attachment',
  'concentration-curl': 'Concentration_Curls',
  'barbell-curl': 'Barbell_Curl',
  'seated-dumbbell-wrist-curl': 'Seated_Dumbbell_Palms-Up_Wrist_Curl',
  'seated-reverse-wrist-curl': 'Seated_Dumbbell_Palms-Down_Wrist_Curl',
  'reverse-barbell-curl': 'Reverse_Barbell_Curl',
  'cable-reverse-curl': 'Reverse_Cable_Curl',
  'cable-wrist-curl': 'Seated_Two-Arm_Palms-Up_Low-Pulley_Wrist_Curl',
  'dumbbell-pullover': 'Straight-Arm_Dumbbell_Pullover',
  'barbell-pullover': 'Bent-Arm_Barbell_Pullover',
  // legs
  'kettlebell-goblet-squat': 'Goblet_Squat',
  'barbell-back-squat': 'Barbell_Squat',
  'smith-squat': 'Smith_Machine_Squat',
  'leg-press': 'Leg_Press',
  'dumbbell-romanian-deadlift': 'Stiff-Legged_Dumbbell_Deadlift',
  'barbell-romanian-deadlift': 'Romanian_Deadlift',
  'cable-pull-through': 'Pull_Through',
  'lying-leg-curl': 'Lying_Leg_Curls',
  'leg-extension': 'Leg_Extensions',
  'dumbbell-reverse-lunge': 'Dumbbell_Rear_Lunge',
  'bulgarian-split-squat': 'Split_Squat_with_Dumbbells',
  'dumbbell-step-up': 'Dumbbell_Step_Ups',
  'barbell-hip-thrust': 'Barbell_Hip_Thrust',
  'hip-abduction-machine': 'Thigh_Abductor',
  'standing-calf-raise': 'Standing_Calf_Raises',
  'box-jump': 'Front_Box_Jump',
  'skater-jump': 'Lateral_Bound',
  'hack-squat': 'Hack_Squat',
  'front-squat': 'Front_Barbell_Squat',
  'dumbbell-sumo-squat': 'Plie_Dumbbell_Squat',
  'dumbbell-walking-lunge': 'Dumbbell_Lunges',
  'trap-bar-deadlift': 'Trap_Bar_Deadlift',
  'conventional-deadlift': 'Barbell_Deadlift',
  'good-morning': 'Good_Morning',
  'smith-romanian-deadlift': 'Smith_Machine_Stiff-Legged_Deadlift',
  'sumo-deadlift': 'Sumo_Deadlift',
  'cable-glute-kickback': 'One-Legged_Cable_Kickback',
  'donkey-kick': 'Glute_Kickback',
  'band-glute-kickback': 'Hip_Extension_with_Bands',
  'seated-leg-curl': 'Seated_Leg_Curl',
  'nordic-curl': 'Floor_Glute-Ham_Raise',
  'hip-adduction-machine': 'Thigh_Adductor',
  'cable-hip-adduction': 'Cable_Hip_Adduction',
  'seated-calf-raise': 'Seated_Calf_Raise',
  'leg-press-calf-raise': 'Calf_Press_On_The_Leg_Press_Machine',
  'smith-calf-raise': 'Smith_Machine_Calf_Raise',
  'single-leg-leg-extension': 'Single-Leg_Leg_Extension',
  'back-extension-45': 'Hyperextensions_Back_Extensions',
  'superman-raise': 'Superman',
  // core (incl. strength-category core work)
  'plank': 'Plank',
  'side-plank': 'Side_Bridge',
  'dead-bug': 'Dead_Bug',
  'hanging-knee-raise': 'Hanging_Leg_Raise',
  'captains-chair-knee-raise': 'Knee_Hip_Raise_On_Parallel_Bars',
  'landmine-rotation': 'Landmine_180s',
  'reverse-crunch': 'Reverse_Crunch',
  'ab-wheel-rollout': 'Ab_Roller',
  'pallof-press-cable': 'Pallof_Press_With_Rotation',
  'cable-crunch': 'Cable_Crunch',
  'standing-cable-crunch': 'Standing_Rope_Crunch',
  'kneeling-cable-oblique-crunch': 'Kneeling_Cable_Crunch_With_Alternating_Oblique_Twists',
  // cool-down
  'cross-body-shoulder-stretch': 'Shoulder_Stretch',
  'triceps-overhead-stretch': 'Triceps_Stretch',
  'childs-pose': 'Childs_Pose',
  'half-kneeling-hip-flexor-stretch': 'Kneeling_Hip_Flexor',
  'split-stance-hip-flexor-stretch': 'Standing_Hip_Flexors',
  'hamstring-stretch': 'Hamstring_Stretch',
  'calf-wall-stretch': 'Calf_Stretch_Hands_Against_Wall',
  'foam-roll-thoracic': 'Rhomboids-SMR',
  'foam-roll-legs': 'Quadriceps-SMR',
  'bench-hamstring-stretch': 'Standing_Gastrocnemius_Calf_Stretch',
  'upper-trap-stretch': 'Side_Neck_Stretch',
  'standing-biceps-stretch': 'Standing_Biceps_Stretch',
  'standing-side-reach': 'Standing_Lateral_Stretch',
  'standing-upper-back-stretch': 'Upper_Back_Stretch',
  'seated-thoracic-rotation': 'Spinal_Stretch',
  'butterfly-stretch': 'Groin_and_Back_Stretch',
  'knee-to-chest-stretch': 'One_Knee_To_Chest',
  'supine-figure-four-stretch': 'Ankle_On_The_Knee',
  'standing-forward-fold': 'Runners_Stretch',
};

// Reviewed and rejected (kept here so they are not re-added by accident):
//   goblet-squat            Goblet_Squat (kettlebell, catalog uses a dumbbell)
//   band-lateral-walk       Monster_Walk (forward steps, ankle band, frames barely differ)
//   pallof-press-cable      Pallof_Press (frame 1 is a zoomed close-up, press-out not visible)
//   kettlebell-swing        One-Arm_Kettlebell_Swings (one-arm, catalog is two-handed)
//   single-leg-romanian-deadlift  Kettlebell_One-Legged_Deadlift (kettlebell, catalog uses dumbbells)
//   suitcase-carry          Farmers_Walk (two loaded hands, not an offset carry)
//   landmine-press          Landmine_Linear_Jammer (standing two-hand jammer, not half-kneeling press)
//   assisted-dip            Dip_Machine (seated dip machine, not assisted dip)
//   standing-quad-stretch   Quad_Stretch (side-lying with a strap)
//   lat-stretch             Overhead_Lat (partner stretch)
//   scapular-push-up        Scapular_Pull-Up (hanging, different movement)
//   smith-split-squat       Smith_Single-Leg_Split_Squat (rear foot on a bench = Bulgarian, lifter hidden by plates)
//   single-arm-cable-row    Seated_One-arm_Cable_Pulley_Rows (seated low row, catalog is standing split stance)
//   (v3 review)
//   low-to-high-cable-fly   Incline_Cable_Flye (seated on an incline bench, not a standing low-to-high fly)
//   lean-away-lateral-raise One-Arm_Side_Laterals (stands upright holding a bench, no lean-away)
//   bar-dip                 Parallel_Bar_Dip (improvised bar hanging from ropes, not a dip station)
//   farmers-carry           Farmers_Walk (strongman farmer's handles outdoors, catalog uses dumbbells)
//   single-leg-dumbbell-calf-raise  Standing_Dumbbell_Calf_Raise / Calf_Raise_On_A_Dumbbell (both legs)
//   reverse-nordic          Weighted_Sissy_Squat (different movement, plate held)
//   nordic-curl             Natural_Glute_Ham_Raise (feet anchored in a glute-ham machine; floor version used)
//   bench-figure-four-stretch  Seated_Glute (partner-assisted, on the floor)
//   standing-adductor-stretch  Adductor_Groin (partner-assisted, lying)
//   lat-stretch             One_Arm_Against_Wall (arm overhead on a wall, no hip sit-back)
//   thoracic-open-book      Side-Lying_Floor_Stretch (overhead reach, no rotation)
//   low-to-high-cable-woodchop  Standing_Cable_Wood_Chop (high-to-low; used for cable-woodchop)
//   (no source photo exists for: machine-lateral-raise, cable-y-raise, bayesian-cable-curl, dead-hang,
//    single-leg-leg-press, smith-reverse-lunge, smith-hip-thrust, copenhagen-plank, cable-hip-abduction,
//    back-extension-machine, ankle-rocks)

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, '..');
const outDir = path.join(appDir, 'assets', 'exercises');
const catalogPath = path.join(appDir, 'assets', 'data', 'catalog.json');

function loadSharp() {
  const toolsDir = process.env.WFIT_TOOLS ?? path.join(os.tmpdir(), 'wfit-tools');
  try {
    return createRequire(path.join(toolsDir, 'package.json'))('sharp');
  } catch {
    return createRequire(import.meta.url)('sharp');
  }
}

async function fetchBuffer(url) {
  for (let attempt = 1; ; attempt++) {
    const res = await fetch(url);
    if (res.ok) return Buffer.from(await res.arrayBuffer());
    if (attempt >= 3) throw new Error(`${res.status} ${url}`);
    await new Promise((r) => setTimeout(r, 1000 * attempt));
  }
}

async function main() {
  const sharp = loadSharp();
  const catalog = JSON.parse(await readFile(catalogPath, 'utf8'));
  const catalogIds = new Set(catalog.exercises.map((e) => e.id));
  const source = JSON.parse((await fetchBuffer(`${RAW}/dist/exercises.json`)).toString('utf8'));
  const sourceById = new Map(source.map((e) => [e.id, e]));

  for (const [id, sourceId] of Object.entries(MAPPING)) {
    if (!sourceById.has(sourceId)) throw new Error(`Source exercise "${sourceId}" not found`);
    if (!catalogIds.has(id)) console.warn(`Skipping "${id}": not in catalog.json`);
  }

  await mkdir(outDir, { recursive: true });
  const exercises = {};
  for (const id of Object.keys(MAPPING).filter((id) => catalogIds.has(id)).sort()) {
    const sourceId = MAPPING[id];
    for (const frame of [0, 1]) {
      const input = await fetchBuffer(`${RAW}/exercises/${sourceId}/${frame}.jpg`);
      const output = await sharp(input)
        .rotate()
        .resize({ width: MAX_WIDTH, withoutEnlargement: true })
        .jpeg({ quality: QUALITY, mozjpeg: true })
        .toBuffer();
      await writeFile(path.join(outDir, `${id}_${frame}.jpg`), output);
    }
    exercises[id] = { frames: 2, sourceId };
    console.log(`${id.padEnd(38)} <- ${sourceId}`);
  }

  // Remove frames of exercises that are no longer mapped.
  for (const file of await readdir(outDir)) {
    const m = /^(.+)_\d+\.jpg$/.exec(file);
    if (m && !exercises[m[1]]) await rm(path.join(outDir, file));
  }

  const index = {
    source: {
      name: 'Free Exercise DB',
      url: `https://github.com/${SOURCE_REPO}`,
      revision: SOURCE_REF,
      license: 'The Unlicense (public domain)',
      licenseUrl: 'https://unlicense.org',
      attribution:
        'Exercise photos from Free Exercise DB by yuhonas and contributors (github.com/yuhonas/free-exercise-db), ' +
        'based on wrkout/exercises.json; released into the public domain under The Unlicense. Resized for W-fit.',
    },
    exercises,
  };
  await writeFile(path.join(outDir, 'index.json'), `${JSON.stringify(index, null, 2)}\n`);

  const unmapped = [...catalogIds].filter((id) => !exercises[id]);
  console.log(`\nMapped ${Object.keys(exercises).length}/${catalogIds.size}. Unmapped: ${unmapped.join(', ')}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
