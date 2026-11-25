package com.jwaegebaert.wfit.watch.timer

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import com.jwaegebaert.wfit.watch.MainActivity
import com.jwaegebaert.wfit.watch.R
import com.jwaegebaert.wfit.watch.core.Workout

/** Shortcut on the watch face and in the launcher while a workout runs, with the running countdown. */
object OngoingWorkout {
    private const val CHANNEL = "workout"
    private const val ID = 1

    fun update(context: Context, workout: Workout, now: Long) {
        val manager = NotificationManagerCompat.from(context)
        if (!workout.isActive(now)) {
            manager.cancel(ID)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Workout", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val running = workout.running(now)
        val text = running?.phaseAt(now)?.label ?: workout.focused?.name ?: workout.snapshot?.title.orEmpty()
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_wfit)
            .setContentTitle("W-fit")
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_WORKOUT)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
        val status = running?.phaseAt(now)?.let { phase ->
            val end = SystemClock.elapsedRealtime() + (phase.endsAt - now)
            Status.Builder().addTemplate("#time#").addPart("time", Status.TimerPart(end)).build()
        } ?: Status.Builder().addTemplate("#text#").addPart("text", Status.TextPart(text)).build()
        OngoingActivity.Builder(context, ID, builder)
            .setStaticIcon(R.drawable.ic_stat_wfit)
            .setTouchIntent(open)
            .setStatus(status)
            .build()
            .apply(context)
        manager.notify(ID, builder.build())
    }
}
