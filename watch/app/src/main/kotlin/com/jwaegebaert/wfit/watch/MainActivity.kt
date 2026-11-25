package com.jwaegebaert.wfit.watch

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.wear.ambient.AmbientLifecycleObserver
import com.jwaegebaert.wfit.watch.core.HeartReading
import com.jwaegebaert.wfit.watch.link.HeartRate
import com.jwaegebaert.wfit.watch.link.WorkoutStore
import com.jwaegebaert.wfit.watch.timer.OngoingWorkout
import com.jwaegebaert.wfit.watch.ui.WatchApp
import com.jwaegebaert.wfit.watch.ui.WfitTheme
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class MainActivity : ComponentActivity() {
    private val ambient = MutableStateFlow(false)
    private val now = MutableStateFlow(WorkoutStore.now())

    private val heart = MutableStateFlow<HeartReading?>(null)
    private val heartAllowed = MutableStateFlow(false)

    private val ask = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        heartAllowed.value = HeartRate.isAllowed(this)
        OngoingWorkout.update(this, WorkoutStore.get(this).workout.value, WorkoutStore.now())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = WorkoutStore.get(this)

        // Always-on: stays on this screen with the wrist down instead of returning to the watch face.
        lifecycle.addObserver(
            AmbientLifecycleObserver(
                this,
                object : AmbientLifecycleObserver.AmbientLifecycleCallback {
                    override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
                        now.value = WorkoutStore.now()
                        ambient.value = true
                    }

                    override fun onUpdateAmbient() {
                        now.value = WorkoutStore.now()
                    }

                    override fun onExitAmbient() {
                        now.value = WorkoutStore.now()
                        ambient.value = false
                    }
                },
            ),
        )

        lifecycleScope.launch {
            store.load()
            store.workout.first { it.isActive(WorkoutStore.now()) }
            askForPermissions()
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                heartAllowed.value = HeartRate.isAllowed(this@MainActivity)
                // The sensor runs only while a workout is on screen.
                combine(heartAllowed, ambient, store.workout) { allowed, dimmed, w ->
                    allowed && !dimmed && w.isActive(WorkoutStore.now())
                }.distinctUntilChanged().flatMapLatest { on ->
                    if (on) HeartRate.readings(this@MainActivity) else emptyFlow()
                }.collect { heart.value = it }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (isActive) {
                    now.value = WorkoutStore.now()
                    if (ambient.value) {
                        ambient.first { !it }
                    } else {
                        store.settle()
                        delay(if (store.runningCountdown() != null) 200 else 1000)
                    }
                }
            }
        }

        setContent { WfitTheme { WatchApp(store, now, ambient, heart) } }
    }

    /** Only once a workout runs, so the questions make sense: the shortcut on the watch face and the heart rate. */
    private fun askForPermissions() {
        val wanted = buildList {
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
            add(HeartRate.permission)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isNotEmpty()) ask.launch(wanted.toTypedArray())
    }
}
