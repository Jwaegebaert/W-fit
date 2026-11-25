package com.jwaegebaert.wfit.watch.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private fun fixture(name: String): String = File("../fixtures/$name").readText()

/** The countdown rules shared with the phone (`app/test/workout_countdown_test.dart` runs the same cases). */
class CountdownTest {
    @Test
    fun sharedCases() {
        val cases = Json.parseToJsonElement(fixture("timers.json")) as JsonArray
        assertTrue(cases.size > 10)
        for (case in cases.map { it.jsonObject }) {
            val name = case["name"]!!.jsonPrimitive.content
            var timer = Json.decodeFromJsonElement(Countdown.serializer(), case["timer"]!!)
            case["extend"]?.let { timer = timer.extend(it.jsonPrimitive.int, case["extendAt"]!!.jsonPrimitive.long) }
            val now = case["now"]!!.jsonPrimitive.long
            val running = timer.at(now)
            val expect = case["expect"]!!
            if (expect is JsonNull) {
                assertNull(name, running)
                continue
            }
            expect as JsonObject
            assertNotNull(name, running)
            assertEquals(name, expect["kind"]!!.jsonPrimitive.content, running!!.kind.name.lowercase())
            assertEquals(name, expect["label"]!!.jsonPrimitive.content, running.phaseAt(now)!!.label)
            assertEquals(name, expect["remaining"]!!.jsonPrimitive.int, running.remaining(now))
            assertEquals(name, expect["endsAt"]!!.jsonPrimitive.long, running.endsAt)
        }
    }

    @Test
    fun newestChangeWins() {
        val older = Countdown.rest("Rest", 60, 1000)
        val stopped = Countdown.none(2000)
        assertEquals(stopped, Countdown.newest(older, stopped))
        assertEquals(stopped, Countdown.newest(stopped, older))
        assertEquals(older, Countdown.newest(null, older))
    }

    @Test
    fun fractionLeftRunsFromOneToZeroInEveryPhase() {
        val ref = SetRef("s", 0, "x", "core", 1, 30, 0, false)
        val work = Countdown.work("Side plank", ref, perSide = true, from = 0)
        assertEquals(1f, work.fractionLeft(0), 0.001f)
        assertEquals(0.5f, work.fractionLeft(15_000), 0.001f)
        assertEquals("time to switch", 1f, work.fractionLeft(30_000), 0.001f)
        assertEquals(1f, work.fractionLeft(35_000), 0.001f)
        assertEquals(0f, work.fractionLeft(65_000), 0.001f)
    }

    @Test
    fun oneSidedRoundsHaveTimeToSwitchBetweenEverySide() {
        val ref = SetRef("s", 0, "x", "cooldown", 1, 15, 0, true, count = 2)
        val work = Countdown.work("Calf stretch", ref, perSide = true, from = 0)
        assertEquals(
            listOf("Side 1 (1/2) · Calf stretch", "Side 2 (1/2) · Calf stretch", "Side 1 (2/2) · Calf stretch", "Side 2 (2/2) · Calf stretch"),
            work.phases.filterNot { it.pause }.map { it.label },
        )
        assertEquals(listOf(5, 5, 5), work.phases.filter { it.pause }.map { it.seconds })
        assertEquals(75_000, work.endsAt)
        assertTrue("extending keeps the switch a switch", work.extend(15, 1000).phases[1].pause)
        val both = Countdown.work("Plank", SetRef("s", 0, "x", "core", 1, 30, 0, true), perSide = false, from = 0)
        assertEquals(listOf("Plank"), both.phases.map { it.label })
    }
}

class ProtocolTest {
    @Test
    fun readsTheSnapshotThePhoneSends() {
        val s = Protocol.snapshot(fixture("snapshot.json"))!!
        assertEquals("s1", s.sessionId)
        assertEquals(1, s.current)
        assertEquals(listOf("e1"), s.acked)
        assertEquals(Countdown.Kind.REST, s.timer!!.kind)
        val (warmup, bench, assisted, dip, plank) = s.exercises
        val row = s.exercises[5]
        assertNull(warmup.weightLabel)
        assertTrue(warmup.perSide)
        assertEquals("Plates kg", bench.weightLabel)
        assertEquals("40 kg plates (+20 bar)", bench.weightText)
        assertEquals(LoggedSet(1, 40.0, 8, null, 1700000100000), bench.logged.single())
        assertEquals(5.0, assisted.step, 0.0)
        assertNull(dip.weight)
        assertEquals(25, plank.seconds)
        assertTrue(plank.isTimed)
        assertTrue(row.numbered)
        assertFalse(bench.numbered)
        assertEquals("the plate used last", "9 × plate 6", row.setSummary())
    }

    /** Fails when the phone adds, drops or renames a field the watch should know. */
    @Test
    fun knowsEveryFieldOfTheSnapshot() {
        Json { ignoreUnknownKeys = false }.decodeFromString(Snapshot.serializer(), fixture("snapshot.json"))
    }

    @Test
    fun writesExactlyTheMessagesThePhoneIsTestedWith() {
        for (message in Json.parseToJsonElement(fixture("events.json")).jsonArray) {
            val text = message.toString()
            val encoded = Protocol.timer(text)?.let(Protocol::encode) ?: Protocol.encode(Protocol.event(text)!!)
            assertEquals(message, Json.parseToJsonElement(encoded))
        }
    }

    @Test
    fun ignoresDamagedAndUnknownMessages() {
        assertNull(Protocol.snapshot("nonsense"))
        assertNull(Protocol.snapshot("{}"))
        assertNull(Protocol.snapshot("""{"v":2,"sessionId":"s1"}"""))
        assertNotNull("new fields are fine", Protocol.snapshot("""{"v":1,"sessionId":null,"somethingNew":1}"""))
    }
}

class WorkoutTest {
    private val start = 1_700_000_000_000
    private val bench = ExerciseInfo(
        order = 0, id = "bench", name = "Bench press", section = "main", sectionLabel = "Workout", target = "3 × 6–10",
        weightText = "40 kg plates (+20 bar)", sets = 3, targetReps = 7, perSide = false, rest = 120,
        weightLabel = "Plates kg", weight = 40.0, step = 2.5,
    )
    private val plank = ExerciseInfo(
        order = 1, id = "side-plank", name = "Side plank", section = "core", sectionLabel = "Core",
        target = "2 × 30s / side", sets = 2, seconds = 30, perSide = true, rest = 45, step = 2.5,
    )
    private val stretch = ExerciseInfo(
        order = 2, id = "stretch", name = "Stretch", section = "cooldown", sectionLabel = "Cool-down",
        target = "1 × 12 / side", sets = 1, targetReps = 12, perSide = true, rest = 0, step = 2.5,
    )

    private fun snapshot(
        bench: ExerciseInfo = this.bench,
        current: Int? = null,
        timer: Countdown? = null,
        acked: List<String> = emptyList(),
        session: String? = "s1",
    ) = Snapshot(
        1, session, "Push", start, current,
        if (session == null) emptyList() else listOf(bench, plank, stretch), timer, acked,
    )

    private val workout = Workout().receive(snapshot())

    private fun Workout.log(now: Long, id: String = "id$now", weight: Double? = 40.0, reps: Int? = 8) =
        logSet(focus, weight, reps, now, id)

    @Test
    fun loggingCountsTheSetAtOnceAndStartsTheRest() {
        val w = workout.log(start + 1000)
        assertEquals(1, w.focused!!.logged.size)
        assertEquals(2, w.focused!!.nextSet)
        val event = w.events.single()
        assertEquals(listOf("s1", "bench", "main"), listOf(event.sessionId, event.exerciseId, event.section))
        assertEquals(listOf(40.0, 8, null), listOf(event.weight, event.reps, event.seconds))
        val rest = w.running(start + 1000)!!
        assertEquals("Rest", rest.phaseAt(start + 1000)!!.label)
        assertEquals(120, rest.remaining(start + 1000))
    }

    @Test
    fun theRestAfterTheLastSetLeadsToTheNextExerciseAndTheWatchMovesOn() {
        val w = workout.log(start + 1000).log(start + 2000).log(start + 3000)
        assertEquals(1, w.focus)
        assertEquals(Countdown.REST_NEXT, w.running(start + 3000)!!.phases.single().label)
    }

    @Test
    fun theNextSetStartsWithTheWeightUsedLast() {
        assertEquals(40.0, workout.focused!!.nextWeight!!, 0.0)
        val w = workout.log(start + 1000, weight = 45.0)
        assertEquals(45.0, w.focused!!.nextWeight!!, 0.0)
        assertEquals("7 × 45 kg", w.focused!!.setSummary())
    }

    @Test
    fun exercisesWithoutWeightFieldNeverSendAWeight() {
        val w = workout.show(2).logSet(2, 20.0, 12, start + 1000, "x")
        assertNull(w.events.single().weight)
        assertNull("no rest configured", w.running(start + 1000))
        assertEquals("12 / side", stretch.setSummary())
        assertEquals("30s / side", plank.setSummary())
    }

    @Test
    fun aWeightedSetNeedsAWeightAndZeroCounts() {
        val w = Workout().receive(snapshot(bench.copy(needsWeight = true, weight = null, weightText = null)))
        assertFalse(w.focused!!.canLog(w.focused!!.nextWeight))
        assertEquals("nothing logged", w, w.log(start + 1000, weight = null))
        assertEquals(0.0, w.log(start + 1000, weight = 0.0).events.single().weight!!, 0.0)
        assertEquals("optional weight", 1, workout.log(start + 1000, weight = null).events.size)
    }

    @Test
    fun aConfirmedEventIsDroppedAndTheSetStays() {
        val w = workout.log(start + 1000, id = "e1")
        val confirmed = bench.copy(logged = listOf(LoggedSet(1, 40.0, 8, null, start + 1000)))
        val after = w.receive(snapshot(bench = confirmed, acked = listOf("e1")))
        assertTrue(after.events.isEmpty())
        assertEquals(1, after.exercises[0].logged.size)
    }

    @Test
    fun anUnconfirmedEventSurvivesOtherSnapshots() {
        val w = workout.log(start + 1000).receive(snapshot(current = null))
        assertEquals(1, w.exercises[0].logged.size)
        assertEquals(1, w.events.size)
    }

    @Test
    fun aNewerEntryOnThePhoneWinsFromAWaitingOne() {
        val w = workout.log(start + 1000, reps = 8)
        val phone = bench.copy(logged = listOf(LoggedSet(1, 45.0, 5, null, start + 9000)))
        assertEquals(5, w.receive(snapshot(bench = phone)).exercises[0].logged.single().reps)
        val older = bench.copy(logged = listOf(LoggedSet(1, 45.0, 5, null, start)))
        assertEquals(8, w.receive(snapshot(bench = older)).exercises[0].logged.single().reps)
    }

    @Test
    fun eventsOfAnotherWorkoutDoNotShowUpInThisOne() {
        val w = workout.log(start + 1000).receive(snapshot(session = "s2"))
        assertTrue(w.exercises[0].logged.isEmpty())
        assertEquals("still to be delivered", 1, w.events.size)
    }

    @Test
    fun undoTakesBackTheSetLoggedLast() {
        val w = workout.log(start + 1000).log(start + 2000).undo(0, start + 3000) { "u" }
        assertEquals(listOf(1), w.exercises[0].logged.map { it.set })
        assertEquals(2, w.exercises[0].nextSet)
        assertEquals(WatchEvent.UNLOG, w.events.last().type)
        assertEquals(2, w.events.last().set)
    }

    @Test
    fun undoOfTheFinalSetGoesBackToThatExercise() {
        val w = workout.log(start + 1000).log(start + 2000).log(start + 3000)
        assertEquals(1, w.focus)
        val undone = w.undo(0, start + 4000) { "u" }
        assertEquals(0, undone.focus)
        assertFalse(undone.focused!!.isDone)
    }

    private val warmup = ExerciseInfo(
        order = 0, id = "circles", name = "Arm circles", section = "warmup", sectionLabel = "Warm-up", target = "2 × 15",
        sets = 2, targetReps = 15, perSide = false, rest = 0, step = 2.5, checklist = true,
    )

    private fun withWarmup() = Workout().receive(
        Snapshot(1, "s1", "Push", start, null, listOf(warmup, bench.copy(order = 1), plank.copy(order = 2))),
    )

    @Test
    fun aWarmupIsTickedOffAndUndoneAsAWhole() {
        var n = 0
        val w = withWarmup().tickOff(0, start + 1000) { "t${n++}" }
        assertEquals(listOf(1, 2), w.events.map { it.set })
        assertEquals(listOf(15, 15), w.events.map { it.reps })
        assertNull("no rest", w.running(start + 1000))
        assertEquals("on to the first lift", 1, w.focus)
        val undone = w.undo(0, start + 2000) { "u${n++}" }
        assertTrue(undone.exercises[0].logged.isEmpty())
        assertEquals(0, undone.focus)
        assertEquals("lifts are logged set by set", w, w.tickOff(1, start + 3000) { "x" })
    }

    @Test
    fun aTimedWarmupStartsNoRest() {
        val drill = warmup.copy(seconds = 30, targetReps = null, sets = 1)
        val w = Workout().receive(Snapshot(1, "s1", "Push", start, null, listOf(drill, bench.copy(order = 1))))
        val settled = w.startWork(0, start + 1000).settle(start + 31_000)
        assertEquals(30, settled.events.single().seconds)
        assertNull(settled.running(start + 31_000))
        assertEquals(1, settled.focus)
    }

    @Test
    fun aOneSidedStretchRunsAllItsRoundsInOneGo() {
        val calf = warmup.copy(section = "cooldown", seconds = 15, targetReps = null, perSide = true)
        val w = Workout().receive(Snapshot(1, "s1", "Push", start, null, listOf(calf)))
        val running = w.startWork(0, start)
        assertTrue(running.settle(start + 74_000).events.isEmpty())
        val settled = running.settle(start + 75_000)
        assertEquals(listOf(1, 2), settled.events.map { it.set })
        assertEquals(listOf(15, 15), settled.events.map { it.seconds })
        assertTrue(settled.exercises[0].isDone)
        assertNull("no rest", settled.running(start + 75_000))
        val second = w.logSet(0, null, null, start, "x").startWork(0, start)
        assertEquals("only what is left", 35_000 + start, second.timer!!.endsAt)
        assertEquals("early end logs all rounds", 2, running.finishWork(start + 9000).events.size)
    }

    @Test
    fun theWatchNeverGoesBackToASkippedWarmup() {
        var w = withWarmup().show(1)
        for (i in 1..3) w = w.log(start + i * 1000)
        assertEquals(2, w.focus)
        w = w.logSet(2, null, null, start + 5000, "p1").logSet(2, null, null, start + 6000, "p2")
        assertEquals(2, w.focus)
        assertTrue("the warm-up does not count", w.isFinished)
    }

    @Test
    fun aSkippedLiftIsComeBackTo() {
        var w = withWarmup().show(2)
        w = w.logSet(2, null, null, start + 5000, "p1").logSet(2, null, null, start + 6000, "p2")
        assertEquals(1, w.focus)
        assertFalse(w.isFinished)
    }

    @Test
    fun aHeartRateIsShownOnlyWhenTrustedAndRecent() {
        assertEquals(128, HeartReading(128, 1000).at(6000))
        assertNull("no contact", HeartReading(0, 1000).at(1000))
        assertNull("too old", HeartReading(128, 1000).at(1000 + HeartReading.MAX_AGE_MS + 1))
    }

    @Test
    fun aDoneExerciseTakesExtraSets() {
        val w = workout.log(start + 1000).log(start + 2000).log(start + 3000).show(0).log(start + 4000)
        assertEquals(4, w.exercises[0].logged.size)
        assertEquals(4, w.events.last().set)
    }

    @Test
    fun oneSidedHoldIsLoggedOnceWhenBothSidesAreDone() {
        val from = start + 1000
        val w = workout.show(1).startWork(1, from)
        assertEquals("Side 1 · Side plank", w.running(from)!!.phaseAt(from)!!.label)
        assertTrue(w.settle(from + 31_000).events.isEmpty())
        assertEquals("Switch sides · Side plank", w.running(from + 31_000)!!.phaseAt(from + 31_000)!!.label)
        val settled = w.settle(from + 70_000)
        val event = settled.events.single()
        assertEquals(30, event.seconds)
        assertEquals("time of the end, not of the delivery", from + 65_000, event.at)
        assertEquals(40, settled.running(from + 70_000)!!.remaining(from + 70_000))
        assertEquals("only once", settled, settled.settle(from + 75_000))
        val twice = w.settle(from + 70_000).let { Workout(it.snapshot, it.events, w.timer, it.focus) }.settle(from + 71_000)
        assertEquals("same id after a restart", 1, twice.events.size)
    }

    @Test
    fun stoppingAWorkCountdownLogsNothing() {
        val w = workout.startWork(1, start + 1000).stopTimer(start + 5000)
        assertNull(w.running(start + 5000))
        assertTrue(w.settle(start + 90_000).events.isEmpty())
    }

    @Test
    fun finishingAHoldEarlyLogsItAndRests() {
        val w = workout.startWork(1, start + 1000).finishWork(start + 5000)
        assertEquals(30, w.events.single().seconds)
        assertEquals(45, w.running(start + 5000)!!.remaining(start + 5000))
    }

    @Test
    fun aCountdownFromThePhoneIsShownButNotLoggedHere() {
        val ref = SetRef("s1", 1, "side-plank", "core", 1, 30, 45, false)
        val timer = Countdown.work("Side plank", ref, perSide = true, from = start + 1000, owner = Countdown.Owner.PHONE)
        val w = workout.receive(snapshot(timer = timer))
        assertTrue(w.running(start + 2000)!!.isWork)
        assertEquals(Countdown.Kind.REST, w.running(start + 67_000)!!.kind)
        assertTrue(w.settle(start + 67_000).events.isEmpty())
    }

    @Test
    fun aWatchCountdownExtendedOnThePhoneIsLoggedAtItsNewEnd() {
        val from = start + 1000
        val w = workout.startWork(1, from)
        val extended = w.timer!!.extend(15, from + 5000)
        val updated = w.receive(snapshot(timer = extended))
        assertTrue(updated.settle(from + 66_000).events.isEmpty())
        assertEquals(from + 80_000, updated.settle(from + 85_000).events.single().at)
    }

    @Test
    fun theNewestTimerChangeWins() {
        val w = workout.log(start + 1000)
        val skipped = w.receive(snapshot(timer = Countdown.none(start + 2000, Countdown.Owner.PHONE)))
        assertNull("skipped on the phone", skipped.running(start + 2500))
        val old = w.receive(snapshot(timer = Countdown.none(start, Countdown.Owner.PHONE)))
        assertNotNull(old.running(start + 2500))
        assertEquals(135, w.extendTimer(15, start + 1000).running(start + 1000)!!.remaining(start + 1000))
    }

    @Test
    fun theWatchFollowsTheExerciseOpenedOnThePhoneOnce() {
        val w = workout.receive(snapshot(current = 2))
        assertEquals(2, w.focus)
        val moved = w.show(0).receive(snapshot(current = 2))
        assertEquals("the phone did not change it again", 0, moved.focus)
        assertEquals(1, moved.receive(snapshot(current = 1)).focus)
    }

    @Test
    fun aSetLoggedOnThePhoneMovesTheWatchOnWhenTheExerciseIsDone() {
        val sets = (1..3).map { LoggedSet(it, 40.0, 8, null, start) }
        assertEquals(0, workout.receive(snapshot(bench.copy(logged = sets.take(2)))).focus)
        assertEquals(1, workout.receive(snapshot(bench.copy(logged = sets))).focus)
    }

    @Test
    fun withoutAWorkoutNothingRunsAndNothingCanBeLogged() {
        val w = workout.log(start + 1000).receive(snapshot(session = null, timer = Countdown.rest("Rest", 60, start)))
        assertNull(w.running(start + 2000))
        assertFalse(w.isActive(start + 2000))
        assertEquals(w, w.logSet(0, 1.0, 1, start, "x"))
        assertFalse("a forgotten workout disappears", workout.isActive(start + Workout.MAX_AGE_MS))
    }

    @Test
    fun waitingCountsOnlyEventsThatTakeLong() {
        val w = workout.log(start + 1000)
        assertEquals(0, w.waiting(start + 2000))
        assertEquals(1, w.waiting(start + 60_000))
    }

    @Test
    fun numbersAreWrittenShort() {
        assertEquals("40", formatKg(40.0))
        assertEquals("42.5", formatKg(42.5))
        assertEquals("1.25", formatKg(1.25))
        assertEquals("1:05", formatClock(65))
    }
}
