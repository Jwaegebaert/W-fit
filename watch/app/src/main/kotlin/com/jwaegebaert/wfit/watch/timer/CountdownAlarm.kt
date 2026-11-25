package com.jwaegebaert.wfit.watch.timer

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.jwaegebaert.wfit.watch.MainActivity
import com.jwaegebaert.wfit.watch.core.Countdown
import com.jwaegebaert.wfit.watch.link.WorkoutStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Wakes the watch at the end of the running phase, also with the screen off. An alarm clock alarm is the only kind the
 * system never postpones; it needs no service that keeps the watch awake in between.
 */
object CountdownAlarm {
    const val EXTRA_KIND = "kind"
    const val KIND_SIDE = "side"
    const val KIND_WORK = "work"
    const val KIND_REST = "rest"

    fun schedule(context: Context, running: Countdown?) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val now = WorkoutStore.now()
        val phase = running?.phaseAt(now)
        if (running == null || phase == null) {
            alarms.cancel(intent(context, null))
            return
        }
        val kind = when {
            !running.isWork -> KIND_REST
            running.phaseIndex(now) < running.phases.lastIndex -> KIND_SIDE
            else -> KIND_WORK
        }
        val show = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        alarms.setAlarmClock(AlarmManager.AlarmClockInfo(phase.endsAt, show), intent(context, kind))
    }

    private fun intent(context: Context, kind: String?): PendingIntent = PendingIntent.getBroadcast(
        context, 0, Intent(context, CountdownReceiver::class.java).putExtra(EXTRA_KIND, kind),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
}

class CountdownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Buzz.play(context, intent.getStringExtra(CountdownAlarm.EXTRA_KIND))
        val store = WorkoutStore.get(context)
        val pending = goAsync()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                store.load()
                store.settle() // logs the set of a finished hold
                CountdownAlarm.schedule(context, store.runningCountdown()) // second side, or the rest after it
                OngoingWorkout.update(context, store.workout.value, WorkoutStore.now())
            } finally {
                pending.finish()
            }
        }
    }
}
