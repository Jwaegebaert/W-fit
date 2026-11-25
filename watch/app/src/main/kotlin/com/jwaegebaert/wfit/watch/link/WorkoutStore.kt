package com.jwaegebaert.wfit.watch.link

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.jwaegebaert.wfit.watch.core.Countdown
import com.jwaegebaert.wfit.watch.core.Paths
import com.jwaegebaert.wfit.watch.core.Protocol
import com.jwaegebaert.wfit.watch.core.WatchEvent
import com.jwaegebaert.wfit.watch.core.Workout
import com.jwaegebaert.wfit.watch.timer.CountdownAlarm
import com.jwaegebaert.wfit.watch.timer.OngoingWorkout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import java.util.UUID

/**
 * The one [Workout] of this process. Nothing is stored in files: the phone's snapshot, this watch's unconfirmed events
 * and its timer are data items, which Google Play services keeps and delivers when the phone is back in reach.
 */
class WorkoutStore private constructor(private val context: Context) {
    private val data: DataClient = Wearable.getDataClient(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val loading = Mutex()
    private var loaded = false

    private val mutable = MutableStateFlow(Workout())
    val workout: StateFlow<Workout> = mutable

    private val isLoaded = MutableStateFlow(false)

    /** False until the data items have been read once. */
    val ready: StateFlow<Boolean> = isLoaded

    /** Reads what Google Play services kept. Call before changing anything. */
    suspend fun load() = loading.withLock {
        if (loaded) return@withLock
        try {
            val items = data.dataItems.await()
            val before = mutable.value
            var w = before
            val stored = items.mapNotNull { it.uri.path }.filter { it.startsWith(Paths.EVENTS) }
            for (item in items) w = w.restore(item)
            items.release()
            loaded = true
            change { w }
            // Tidy up: events the phone has confirmed, and events from before Google Play services answered.
            for (path in stored) if (mutable.value.events.none { path(it) == path }) delete(path)
            for (event in before.events) put(path(event), Protocol.encode(event))
        } catch (e: Exception) {
            // No Google Play services (or still starting): the next call tries again.
            Log.w(TAG, "Reading data items failed", e)
        }
        isLoaded.value = true
        settle()
    }

    private fun Workout.restore(item: DataItem): Workout {
        val text = item.data?.decodeToString() ?: return this
        val path = item.uri.path ?: return this
        return when {
            path == Paths.SNAPSHOT -> Protocol.snapshot(text)?.let { receive(it) } ?: this
            path == Paths.TIMER -> copy(timer = Countdown.newest(timer, Protocol.timer(text)))
            path.startsWith(Paths.EVENTS) -> {
                val event = Protocol.event(text) ?: return this
                val keep = event.id !in snapshot?.acked.orEmpty() && now() - event.at < MAX_EVENT_AGE_MS &&
                    events.none { it.id == event.id }
                if (keep) copy(events = events + event) else this
            }
            else -> this
        }
    }

    /** A new snapshot from the phone. */
    fun receive(text: String) {
        val snapshot = Protocol.snapshot(text) ?: return
        change { it.receive(snapshot) }
    }

    fun log(order: Int, weight: Double?, reps: Int?) = change { it.logSet(order, weight, reps, now(), newId()) }
    fun tickOff(order: Int) = change { it.tickOff(order, now(), ::newId) }
    fun undo(order: Int) = change { it.undo(order, now(), ::newId) }
    fun startWork(order: Int) = change { it.startWork(order, now()) }
    fun finishWork() = change { it.finishWork(now()) }
    fun stopTimer() = change { it.stopTimer(now()) }
    fun extendTimer(seconds: Int) = change { it.extendTimer(seconds, now()) }
    fun show(order: Int) = change { it.show(order) }

    /** Logs a work countdown that has ended here. */
    fun settle() = change { it.settle(now()) }

    private fun change(update: (Workout) -> Workout) {
        val old = mutable.value
        val new = update(old).settle(now())
        if (new == old) return
        mutable.value = new
        if (loaded) send(old, new)
        CountdownAlarm.schedule(context, new.running(now()))
        OngoingWorkout.update(context, new, now())
    }

    /** Writes the difference to the data items. */
    private fun send(old: Workout, new: Workout) {
        for (event in new.events - old.events.toSet()) put(path(event), Protocol.encode(event))
        for (event in old.events.filter { o -> new.events.none { it.id == o.id } }) delete(path(event))
        val timer = new.timer
        if (timer != null && timer != old.timer) put(Paths.TIMER, Protocol.encode(timer))
    }

    private fun path(event: WatchEvent) = Paths.EVENTS + event.id

    private fun put(path: String, text: String) = scope.launch {
        try {
            val request = PutDataRequest.create(path).setUrgent()
            request.data = text.toByteArray()
            data.putDataItem(request).await()
        } catch (e: Exception) {
            Log.w(TAG, "Writing $path failed", e)
        }
    }

    private fun delete(path: String) = scope.launch {
        try {
            data.deleteDataItems(android.net.Uri.Builder().scheme(PutDataRequest.WEAR_URI_SCHEME).path(path).build()).await()
        } catch (e: Exception) {
            Log.w(TAG, "Deleting $path failed", e)
        }
    }

    fun runningCountdown(): Countdown? = mutable.value.running(now())

    companion object {
        private const val TAG = "wfit"

        /** Events the phone never took (app reinstalled) are given up after two weeks. */
        private const val MAX_EVENT_AGE_MS = 14 * 24 * 60 * 60 * 1000L

        @Volatile
        private var instance: WorkoutStore? = null

        fun get(context: Context): WorkoutStore = instance ?: synchronized(this) {
            instance ?: WorkoutStore(context.applicationContext).also { instance = it }
        }

        fun now(): Long = System.currentTimeMillis()

        private fun newId(): String = UUID.randomUUID().toString()
    }
}
