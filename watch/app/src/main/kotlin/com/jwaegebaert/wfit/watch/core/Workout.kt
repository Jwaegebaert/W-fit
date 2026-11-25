package com.jwaegebaert.wfit.watch.core

import java.util.Locale

/**
 * What the watch knows: the phone's last [snapshot], its own [events] the phone has not confirmed yet, and its own
 * [timer]. Pure and immutable; every change returns a new value, so the rules are tested without a device.
 */
data class Workout(
    val snapshot: Snapshot? = null,
    val events: List<WatchEvent> = emptyList(),
    val timer: Countdown? = null,
    /** Order of the exercise on screen. */
    val focus: Int = 0,
) {
    val sessionId: String? get() = snapshot?.sessionId

    /** Exercises as the user sees them: the phone's sets with the unconfirmed ones from the watch on top. */
    val exercises: List<ExerciseInfo> by lazy {
        val session = sessionId ?: return@lazy emptyList()
        snapshot!!.exercises.map { e -> overlay(e, events.filter { it.sessionId == session }) }
    }

    val focused: ExerciseInfo? get() = exercises.getOrNull(focus)

    /** Everything but the warm-up is done: nobody goes back for that. */
    val isFinished: Boolean get() = exercises.isNotEmpty() && exercises.filterNot { it.isWarmup }.all { it.isDone }

    /** The countdown both devices agree on; may already be over. */
    private val register: Countdown? get() = Countdown.newest(snapshot?.timer, timer)

    fun running(now: Long): Countdown? = if (isActive(now)) register?.at(now) else null

    /** A workout nobody finished should not stay on the watch for days. */
    fun isActive(now: Long): Boolean = sessionId != null && now - snapshot!!.startedAt < MAX_AGE_MS

    /** Events that have waited a while: the phone is probably out of reach. */
    fun waiting(now: Long): Int = events.count { now - it.at > WAITING_MS }

    /** Takes over a new snapshot: drops confirmed events and moves to the exercise the user is now on. */
    fun receive(next: Snapshot): Workout {
        val updated = copy(snapshot = next, events = events.filter { it.id !in next.acked })
        return updated.copy(focus = focusAfter(this, updated))
    }

    fun logSet(order: Int, weight: Double?, reps: Int?, now: Long, id: String): Workout {
        val e = exercises.getOrNull(order) ?: return this
        val session = sessionId ?: return this
        if (!e.canLog(weight)) return this
        val set = e.nextSet
        val event = WatchEvent(
            type = WatchEvent.LOG,
            id = id,
            at = now,
            sessionId = session,
            order = order,
            exerciseId = e.id,
            section = e.section,
            set = set,
            weight = if (e.isTimed || e.weightLabel == null) null else weight,
            reps = if (e.isTimed) null else reps,
            seconds = e.seconds,
        )
        val rest = if (e.rest > 0) Countdown.rest(restLabel(set >= e.setCount), e.rest, now) else null
        return add(event).copy(timer = rest ?: timer)
    }

    /** Ticks off a warm-up or cool-down exercise: all its open sets at once. */
    fun tickOff(order: Int, now: Long, newId: () -> String): Workout {
        val e = exercises.getOrNull(order) ?: return this
        if (!e.checklist) return this
        return (e.logged.size until e.sets).fold(this) { w, _ -> w.logSet(order, null, e.nextReps, now, newId()) }
    }

    /** Un-logs the set logged last in this exercise; all sets of a warm-up or cool-down exercise. */
    fun undo(order: Int, now: Long, newId: () -> String): Workout {
        val e = exercises.getOrNull(order) ?: return this
        val session = sessionId ?: return this
        val sets = if (e.checklist) e.logged else listOfNotNull(e.undoable)
        return sets.fold(this) { w, set ->
            w.add(
                WatchEvent(
                    type = WatchEvent.UNLOG,
                    id = newId(),
                    at = now,
                    sessionId = session,
                    order = order,
                    exerciseId = e.id,
                    section = e.section,
                    set = set.set,
                ),
            )
        }.copy(focus = order)
    }

    /** Starts the work countdown of a timed set. */
    fun startWork(order: Int, now: Long): Workout {
        val e = exercises.getOrNull(order) ?: return this
        val session = sessionId ?: return this
        val seconds = e.seconds ?: return this
        val ref = SetRef(session, order, e.id, e.section, e.nextSet, seconds, e.rest, e.nextSet >= e.setCount)
        return copy(timer = Countdown.work(e.name, ref, e.perSide, now))
    }

    /** Stops the running countdown without logging anything. */
    fun stopTimer(now: Long): Workout = if (running(now) == null) this else copy(timer = Countdown.none(now))

    fun extendTimer(seconds: Int, now: Long): Workout {
        val current = running(now) ?: return this
        return copy(timer = current.extend(seconds, now))
    }

    /** Ends a running work countdown early and logs its set, as the check mark on the phone does. */
    fun finishWork(now: Long): Workout {
        val current = running(now) ?: return this
        val ref = current.set ?: return this
        if (!current.isWork) return this
        val rest = if (ref.rest > 0) Countdown.rest(restLabel(ref.last), ref.rest, now) else Countdown.none(now)
        return logWork(ref, now, current.changedAt).copy(timer = rest)
    }

    /**
     * Logs the set of a work countdown that was started here and has ended. Safe to call any number of times: the
     * event id is fixed and the countdown is replaced by the rest after it.
     */
    fun settle(now: Long): Workout {
        val c = register ?: return this
        val ref = c.set ?: return this
        if (!c.isWork || c.owner != Countdown.Owner.WATCH || !c.isOver(now)) return this
        return logWork(ref, c.endsAt, c.changedAt).copy(timer = c.restAfter ?: Countdown.none(c.endsAt))
    }

    fun show(order: Int): Workout = if (order in exercises.indices) copy(focus = order) else this

    private fun logWork(ref: SetRef, at: Long, startedAt: Long): Workout = add(
        WatchEvent(
            type = WatchEvent.LOG,
            id = "work-$startedAt-${ref.order}-${ref.set}",
            at = at,
            sessionId = ref.sessionId,
            order = ref.order,
            exerciseId = ref.exerciseId,
            section = ref.section,
            set = ref.set,
            seconds = ref.seconds,
        ),
    )

    private fun restLabel(last: Boolean) = if (last) Countdown.REST_NEXT else Countdown.REST

    private fun add(event: WatchEvent): Workout {
        if (events.any { it.id == event.id }) return this
        val updated = copy(events = events + event)
        return updated.copy(focus = focusAfter(this, updated))
    }

    companion object {
        const val MAX_AGE_MS = 8 * 60 * 60 * 1000L
        const val WAITING_MS = 5_000L

        /** Newest entry per set wins, compared in whole seconds like the phone's database. */
        private fun overlay(e: ExerciseInfo, events: List<WatchEvent>): ExerciseInfo {
            val sets = e.logged.associateBy { it.set }.toMutableMap()
            for (ev in events.filter { it.order == e.order && it.exerciseId == e.id }.sortedBy { it.at }) {
                val existing = sets[ev.set]
                if (existing != null && existing.at / 1000 > ev.at / 1000) continue
                if (ev.isLog) {
                    sets[ev.set] = LoggedSet(ev.set, ev.weight, ev.reps, ev.seconds, ev.at)
                } else {
                    sets.remove(ev.set)
                }
            }
            return e.copy(logged = sets.values.sortedBy { it.set })
        }

        private fun focusAfter(old: Workout, new: Workout): Int {
            val exercises = new.exercises
            if (exercises.isEmpty()) return 0
            // Forward first; back to the start only for work that was skipped, never for the warm-up.
            fun firstOpen(from: Int): Int? =
                (exercises.drop(from) + exercises.take(from).filterNot { it.isWarmup }).firstOrNull { !it.isDone }?.order
            val current = new.snapshot?.current?.takeIf { it in exercises.indices }
            if (old.sessionId != new.sessionId) return current ?: firstOpen(0) ?: 0
            if (current != null && current != old.snapshot?.current) return current
            val focus = old.focus.coerceIn(exercises.indices)
            val was = old.exercises.getOrNull(focus)
            return if (was != null && !was.isDone && exercises[focus].isDone) firstOpen(focus) ?: focus else focus
        }
    }
}

/** A heart rate from the sensor; 0 when the sensor does not trust it. */
data class HeartReading(val bpm: Int, val at: Long) {
    /** What to show at [now]: nothing when untrusted or too old. */
    fun at(now: Long): Int? = bpm.takeIf { it > 0 && now - at <= MAX_AGE_MS }

    companion object {
        const val MAX_AGE_MS = 15_000L
    }
}

/** "42.5", "40". */
fun formatKg(kg: Double): String =
    if (kg == Math.rint(kg)) kg.toLong().toString() else String.format(Locale.ROOT, "%.2f", kg).trimEnd('0')

/** "1:05". */
fun formatClock(seconds: Int): String = String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60)

/** "7 × 42.5 kg", "12 / side", "25s / side". */
fun ExerciseInfo.setSummary(weight: Double? = nextWeight, reps: Int = nextReps): String {
    val side = if (perSide) " / side" else ""
    if (seconds != null) return "${seconds}s$side"
    val kg = if (weightLabel != null && weight != null) " × ${formatKg(weight)} kg" else ""
    return "$reps$side$kg"
}
