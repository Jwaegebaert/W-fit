package com.jwaegebaert.wfit.watch.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive

/**
 * Messages between phone and watch, mirrored by `watch_protocol.dart`. The phone owns the session and sends snapshots;
 * the watch answers with events. The examples in `watch/fixtures` are tested on both sides.
 */
const val PROTOCOL_VERSION = 1

/** Data Layer paths. */
object Paths {
    const val SNAPSHOT = "/wfit/session"
    const val EVENTS = "/wfit/event/"
    const val TIMER = "/wfit/timer"
}

@Serializable
data class LoggedSet(
    val set: Int,
    val weight: Double? = null,
    val reps: Int? = null,
    val seconds: Int? = null,
    val at: Long,
)

/** One exercise; every label is worked out by the phone. */
@Serializable
data class ExerciseInfo(
    val order: Int,
    val id: String,
    val name: String,
    val section: String,
    val sectionLabel: String,
    val target: String,
    val weightText: String? = null,
    val sets: Int,
    val targetReps: Int? = null,
    /** Seconds per set (per side for one-sided holds); null for rep sets. */
    val seconds: Int? = null,
    val perSide: Boolean,
    val rest: Int,
    /** "Plates kg", "Assist kg", "Extra kg" or "kg"; null when the exercise has no weight field. */
    val weightLabel: String? = null,
    /** Working sets on weighted exercises cannot be logged without a weight. */
    val needsWeight: Boolean = false,
    val weight: Double? = null,
    val step: Double,
    /** Warm-up or cool-down: ticked off as a whole, all sets at once and without rest. */
    val checklist: Boolean = false,
    val logged: List<LoggedSet> = emptyList(),
) {
    val isTimed: Boolean get() = seconds != null
    val isWarmup: Boolean get() = section == "warmup"
    val isDone: Boolean get() = logged.size >= sets

    /** Planned sets plus any extra ones that were logged. */
    val setCount: Int get() = maxOf(sets, logged.maxOfOrNull { it.set } ?: 0)

    /** First set that is not logged yet (an extra one when all are done). */
    val nextSet: Int get() = generateSequence(1) { it + 1 }.first { n -> logged.none { it.set == n } }

    private val lastLogged: LoggedSet? get() = logged.maxByOrNull { it.set }

    /** Most recently logged set, the one to undo. */
    val undoable: LoggedSet? get() = logged.maxWithOrNull(compareBy({ it.at }, { it.set }))

    /** Weight to start the next set with: what was used last in this workout, otherwise the plan's. */
    val nextWeight: Double? get() = lastLogged?.weight ?: weight

    val nextReps: Int get() = targetReps ?: 10

    /** Whether a set with [weight] may be logged (0 counts: the empty bar). */
    fun canLog(weight: Double?): Boolean = !needsWeight || weight != null
}

/** Everything the phone tells the watch. [sessionId] is null when no workout is active. */
@Serializable
data class Snapshot(
    val v: Int,
    val sessionId: String? = null,
    val title: String = "",
    val startedAt: Long = 0,
    /** Exercise the user opened on the phone. */
    val current: Int? = null,
    val exercises: List<ExerciseInfo> = emptyList(),
    val timer: Countdown? = null,
    /** Events the phone has handled. */
    val acked: List<String> = emptyList(),
)

/** A set logged or undone on the watch. */
@Serializable
data class WatchEvent(
    val v: Int = PROTOCOL_VERSION,
    /** `log` | `unlog` */
    val type: String,
    val id: String,
    val at: Long,
    val sessionId: String,
    val order: Int,
    val exerciseId: String,
    val section: String,
    val set: Int,
    val weight: Double? = null,
    val reps: Int? = null,
    val seconds: Int? = null,
) {
    val isLog: Boolean get() = type == LOG

    companion object {
        const val LOG = "log"
        const val UNLOG = "unlog"
    }
}

@Serializable
private data class TimerMessage(val v: Int = PROTOCOL_VERSION, val type: String = "timer", val timer: Countdown)

object Protocol {
    private val json = Json {
        ignoreUnknownKeys = true // a newer phone app may send more
        encodeDefaults = true
    }

    /** Null for a damaged message or another protocol version. */
    fun snapshot(text: String): Snapshot? = parse(text) { json.decodeFromString(Snapshot.serializer(), it) }

    fun event(text: String): WatchEvent? = parse(text) { json.decodeFromString(WatchEvent.serializer(), it) }

    fun timer(text: String): Countdown? = parse(text) { json.decodeFromString(TimerMessage.serializer(), it) }?.timer

    fun encode(event: WatchEvent): String = json.encodeToString(WatchEvent.serializer(), event)

    fun encode(timer: Countdown): String = json.encodeToString(TimerMessage.serializer(), TimerMessage(timer = timer))

    private fun <T> parse(text: String, decode: (String) -> T): T? = runCatching {
        val version = (json.parseToJsonElement(text) as JsonObject)["v"]?.jsonPrimitive?.int
        if (version == PROTOCOL_VERSION) decode(text) else null
    }.getOrNull()
}
