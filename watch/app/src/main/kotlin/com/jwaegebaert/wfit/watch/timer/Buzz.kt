package com.jwaegebaert.wfit.watch.timer

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/** Vibration at the end of a countdown phase; each kind feels different. Alarm usage also works in the background. */
object Buzz {
    fun play(context: Context, kind: String?) {
        val vibrator = vibrator(context)
        val pattern = when (kind) {
            CountdownAlarm.KIND_SIDE -> longArrayOf(0, 150, 100, 150) // switch sides
            CountdownAlarm.KIND_GO -> longArrayOf(0, 300) // other side starts
            CountdownAlarm.KIND_WORK -> longArrayOf(0, 600) // hold done
            else -> longArrayOf(0, 300, 150, 300, 150, 300) // rest over
        }
        val effect = VibrationEffect.createWaveform(pattern, -1)
        if (Build.VERSION.SDK_INT >= 33) {
            vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
        }
    }

    private fun vibrator(context: Context): Vibrator =
        if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
}
