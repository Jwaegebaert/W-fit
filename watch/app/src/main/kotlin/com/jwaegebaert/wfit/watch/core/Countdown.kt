@file:OptIn(ExperimentalSerializationApi::class)

package com.jwaegebaert.wfit.watch.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.math.max

/**
 * Countdown shared by the phone and the watch, mirrored by `workout_countdown.dart` (both run
 * `watch/fixtures/timers.json`). Everything is derived from absolute end times in epoch milliseconds, so both devices
 * work out the same phase, remaining time and follow-up rest on their own.
 */
@Serializable
data class Countdown(
    val kind: Kind,
    val owner: Owner,
    /** Last change by a person (start, extend, stop); the newest one wins between phone and watch. */
    val changedAt: Long,
    val phases: List<Phase> = emptyList(),
    val set: SetRef? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("none") NONE,
        @SerialName("rest") REST,
        @SerialName("work") WORK,
    }

    /** Device that started it. Only the owner logs the set when a work countdown ends. */
    @Serializable
    enum class Owner {
        @SerialName("phone") PHONE,
        @SerialName("watch") WATCH,
    }

    @Serializable
    data class Phase(
        val label: String,
        val seconds: Int,
        val endsAt: Long,
        /** Time to change sides inside a work countdown, not work itself. */
        @EncodeDefault(EncodeDefault.Mode.NEVER) val pause: Boolean = false,
    )

    val isWork: Boolean get() = kind == Kind.WORK

    /** When the last phase ends. */
    val endsAt: Long get() = phases.lastOrNull()?.endsAt ?: changedAt

    fun isOver(now: Long): Boolean = kind == Kind.NONE || now >= endsAt

    /** Index of the phase running at [now] (the last one once it is over). */
    fun phaseIndex(now: Long): Int {
        val i = phases.indexOfFirst { now < it.endsAt }
        return if (i >= 0) i else max(0, phases.size - 1)
    }

    fun phaseAt(now: Long): Phase? = phases.getOrNull(phaseIndex(now))

    /** Whole seconds left in the phase running at [now], rounded up. */
    fun remaining(now: Long): Int {
        val left = (phaseAt(now) ?: return 0).endsAt - now
        return max(0L, (left + 999) / 1000).toInt()
    }

    /** Part of the running phase that is left, 1 at its start and 0 at its end. */
    fun fractionLeft(now: Long): Float {
        val phase = phaseAt(now) ?: return 0f
        if (phase.seconds <= 0) return 0f
        return ((phase.endsAt - now) / (phase.seconds * 1000f)).coerceIn(0f, 1f)
    }

    /** Lengthens (or shortens) the running phase and moves the later ones along. A phase cannot end before [now]. */
    fun extend(seconds: Int, now: Long): Countdown {
        if (isOver(now)) return this
        val i = phaseIndex(now)
        val shift = max(seconds * 1000L, now - phases[i].endsAt)
        return copy(
            changedAt = now,
            phases = phases.mapIndexed { p, phase ->
                when {
                    p < i -> phase
                    p == i -> phase.copy(seconds = max(0, phase.seconds + seconds), endsAt = phase.endsAt + shift)
                    else -> phase.copy(endsAt = phase.endsAt + shift)
                }
            },
        )
    }

    /** Rest that follows this work countdown, starting when the work ended; null when there is none. */
    val restAfter: Countdown?
        get() {
            if (!isWork || set == null || set.rest <= 0) return null
            return rest(if (set.last) REST_NEXT else REST, set.rest, endsAt, owner)
        }

    /** What is running at [now]: this countdown, the rest after it, or null. */
    fun at(now: Long): Countdown? = when {
        kind == Kind.NONE -> null
        !isOver(now) -> this
        else -> restAfter?.at(now)
    }

    companion object {
        const val REST = "Rest"
        const val REST_NEXT = "Rest · next exercise"

        /** A stopped countdown; its [changedAt] makes it win from an older running one on the other device. */
        fun none(at: Long, owner: Owner = Owner.WATCH) = Countdown(Kind.NONE, owner, at)

        fun rest(label: String, seconds: Int, from: Long, owner: Owner = Owner.WATCH) =
            Countdown(Kind.REST, owner, from, listOf(Phase(label, seconds, from + seconds * 1000L)))

        /** Time to change sides in a one-sided hold. */
        const val SIDE_SWITCH_SECONDS = 5
        const val SWITCH = "Switch sides"

        /**
         * Work countdown for [set]; one-sided exercises run one phase per side with [SIDE_SWITCH_SECONDS] in between,
         * and go round again for every further set it covers.
         */
        fun work(name: String, set: SetRef, perSide: Boolean, from: Long, owner: Owner = Owner.WATCH): Countdown {
            val phases = mutableListOf<Phase>()
            var end = from
            fun add(label: String, seconds: Int, pause: Boolean = false) {
                end += seconds * 1000L
                phases += Phase(label, seconds, end, pause)
            }
            for (round in 1..set.count) {
                val of = if (set.count > 1) " ($round/${set.count})" else ""
                for (side in 1..(if (perSide) 2 else 1)) {
                    if (perSide && phases.isNotEmpty()) add("$SWITCH · $name", SIDE_SWITCH_SECONDS, pause = true)
                    add(if (perSide) "Side $side$of · $name" else "$name$of", set.seconds)
                }
            }
            return Countdown(Kind.WORK, owner, from, phases, set)
        }

        fun newest(a: Countdown?, b: Countdown?): Countdown? = when {
            a == null -> b
            b == null -> a
            b.changedAt > a.changedAt -> b
            else -> a
        }
    }
}

/** The set a work countdown belongs to. */
@Serializable
data class SetRef(
    val sessionId: String,
    val order: Int,
    val exerciseId: String,
    val section: String,
    val set: Int,
    /** Seconds stored for the set (per side for one-sided holds). */
    val seconds: Int,
    /** Rest after the set, in seconds. */
    val rest: Int,
    /** Last set of the exercise: the rest leads to the next exercise. */
    val last: Boolean,
    /** Sets one work countdown runs through in a row, starting with [set] (one-sided stretches: all of them). */
    @EncodeDefault(EncodeDefault.Mode.NEVER) val count: Int = 1,
)
