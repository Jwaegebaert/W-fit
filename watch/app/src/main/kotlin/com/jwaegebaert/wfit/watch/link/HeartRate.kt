package com.jwaegebaert.wfit.watch.link

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import com.jwaegebaert.wfit.watch.core.HeartReading
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Live heart rate from the watch's sensor, only to look at: nothing is stored or sent. It does not start an exercise,
 * so a recording in Samsung Health keeps running.
 */
object HeartRate {
    /** Wear OS 6 split the heart rate off from the body sensors. */
    val permission: String =
        if (Build.VERSION.SDK_INT >= 36) "android.permission.health.READ_HEART_RATE" else Manifest.permission.BODY_SENSORS

    fun isAllowed(context: Context): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Readings for as long as someone collects; the sensor is off otherwise. */
    fun readings(context: Context): Flow<HeartReading> = callbackFlow {
        val manager = context.getSystemService(SensorManager::class.java)
        val sensor = manager.getDefaultSensor(Sensor.TYPE_HEART_RATE)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val trusted = event.accuracy > SensorManager.SENSOR_STATUS_UNRELIABLE
                trySend(HeartReading(if (trusted) event.values[0].toInt() else 0, WorkoutStore.now()))
            }

            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit
        }
        if (sensor != null) manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        awaitClose { manager.unregisterListener(listener) }
    }
}
