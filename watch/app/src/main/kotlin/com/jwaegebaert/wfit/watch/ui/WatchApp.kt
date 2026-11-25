package com.jwaegebaert.wfit.watch.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.foundation.pager.VerticalPager
import androidx.wear.compose.foundation.pager.rememberPagerState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.CompactButton
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.SwipeToDismissBox
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.VerticalPagerScaffold
import com.jwaegebaert.wfit.watch.R
import com.jwaegebaert.wfit.watch.core.Countdown
import com.jwaegebaert.wfit.watch.core.ExerciseInfo
import com.jwaegebaert.wfit.watch.core.HeartReading
import com.jwaegebaert.wfit.watch.core.Workout
import com.jwaegebaert.wfit.watch.core.formatClock
import com.jwaegebaert.wfit.watch.core.setSummary
import com.jwaegebaert.wfit.watch.link.WorkoutStore
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.drop

private enum class Overlay { NONE, TIMER, ADJUST }

@Composable
fun WatchApp(
    store: WorkoutStore,
    nowFlow: StateFlow<Long>,
    ambientFlow: StateFlow<Boolean>,
    heartFlow: StateFlow<HeartReading?>,
) {
    val workout by store.workout.collectAsStateWithLifecycle()
    val ready by store.ready.collectAsStateWithLifecycle()
    val now by nowFlow.collectAsStateWithLifecycle()
    val ambient by ambientFlow.collectAsStateWithLifecycle()
    val heart by heartFlow.collectAsStateWithLifecycle()
    val running = workout.running(now)

    when {
        ambient -> AmbientScreen(workout, running, now)
        !ready -> Message("W-fit", "")
        !workout.isActive(now) -> Message("No workout", "Start one on your phone; it opens here by itself.")
        workout.exercises.isEmpty() -> Message(workout.snapshot!!.title, "This workout has no exercises.")
        else -> ActiveWorkout(store, workout, running, now, heart?.at(now))
    }
}

@Composable
private fun ActiveWorkout(store: WorkoutStore, workout: Workout, running: Countdown?, now: Long, bpm: Int?) {
    var overlay by remember { mutableStateOf(if (running != null) Overlay.TIMER else Overlay.NONE) }

    // A new countdown comes to the front, wherever it was started; when it is over the exercise returns.
    LaunchedEffect(running?.kind, running?.changedAt) {
        if (running != null) overlay = Overlay.TIMER else if (overlay == Overlay.TIMER) overlay = Overlay.NONE
    }

    if (overlay == Overlay.NONE) {
        ExercisePager(
            store, workout, running, now, bpm,
            onAdjust = { overlay = Overlay.ADJUST },
            onTimer = { overlay = Overlay.TIMER },
        )
        return
    }
    BackHandler { overlay = Overlay.NONE }
    SwipeToDismissBox(onDismissed = { overlay = Overlay.NONE }) { isBackground ->
        when {
            isBackground -> Box(Modifier.fillMaxSize().background(Color.Black))
            overlay == Overlay.TIMER && running != null -> TimerScreen(store, workout, running, now, bpm)
            overlay == Overlay.ADJUST -> workout.focused?.let { e ->
                AdjustScreen(
                    e,
                    onLog = { weight, reps ->
                        overlay = Overlay.NONE
                        store.log(e.order, weight, reps)
                    },
                    onUndo = {
                        overlay = Overlay.NONE
                        store.undo(e.order)
                    },
                )
            }
        }
    }
}

@Composable
private fun ExercisePager(
    store: WorkoutStore,
    workout: Workout,
    running: Countdown?,
    now: Long,
    bpm: Int?,
    onAdjust: () -> Unit,
    onTimer: () -> Unit,
) {
    val exercises = workout.exercises
    val count by rememberUpdatedState(exercises.size)
    val pager = rememberPagerState(initialPage = workout.focus) { count }
    LaunchedEffect(workout.focus) {
        if (pager.currentPage != workout.focus) pager.animateScrollToPage(workout.focus)
    }
    LaunchedEffect(pager) {
        snapshotFlow { pager.settledPage }.drop(1).collect { store.show(it) }
    }
    AppScaffold {
        VerticalPagerScaffold(pagerState = pager) {
            VerticalPager(state = pager) { page ->
                exercises.getOrNull(page)?.let { e ->
                    ExercisePage(store, workout, e, running, now, bpm, onAdjust, onTimer)
                }
            }
        }
    }
}

@Composable
private fun ExercisePage(
    store: WorkoutStore,
    workout: Workout,
    e: ExerciseInfo,
    running: Countdown?,
    now: Long,
    bpm: Int?,
    onAdjust: () -> Unit,
    onTimer: () -> Unit,
) {
    val config = LocalConfiguration.current
    val side = (config.screenWidthDp * 0.1f).dp
    // Countdown on top, small watches and large text: the kg label gives way (the button below still shows the weight).
    val tight = running != null || config.screenHeightDp / config.fontScale < 210
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Column(
            modifier = Modifier.fillMaxSize().padding(start = side, end = side, top = 24.dp, bottom = 60.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (running != null) {
                CompactButton(
                    onClick = onTimer,
                    colors = ButtonDefaults.filledTonalButtonColors(),
                    label = {
                        Text(
                            formatClock(running.remaining(now)),
                            color = timerColor(running),
                            fontWeight = FontWeight.Bold,
                        )
                    },
                )
            } else {
                Text(
                    buildAnnotatedString {
                        if (bpm != null) withStyle(SpanStyle(Brand.work)) { append("${heartLabel(bpm)}  ") }
                        append(header(workout, e, now))
                    },
                    style = MaterialTheme.typography.labelSmall,
                    color = if (workout.waiting(now) > 0) Brand.gold else MaterialTheme.colorScheme.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                e.name,
                modifier = Modifier.fillMaxWidth(),
                style = if (tight) MaterialTheme.typography.titleSmall else MaterialTheme.typography.titleMedium,
                textAlign = TextAlign.Center,
                maxLines = if (tight) 1 else 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(e.target, e.weightText.takeUnless { tight }).joinToString("\n"),
                modifier = Modifier.fillMaxWidth(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (e.checklist) {
                if (e.isTimed && !e.isDone) {
                    CompactButton(
                        onClick = { store.tickOff(e.order) },
                        colors = ButtonDefaults.filledTonalButtonColors(),
                        label = { Text("Done", maxLines = 1) },
                    )
                }
            } else if (!e.isTimed) {
                CompactButton(
                    onClick = onAdjust,
                    colors = ButtonDefaults.filledTonalButtonColors(),
                    icon = { Icon(painterResource(R.drawable.ic_edit), contentDescription = null, Modifier.size(14.dp)) },
                    label = { Text(e.setSummary(), maxLines = 1) },
                )
            } else if (e.undoable != null) {
                CompactButton(
                    onClick = { store.undo(e.order) },
                    colors = ButtonDefaults.filledTonalButtonColors(),
                    label = { Text("Undo set ${e.undoable!!.set}", maxLines = 1) },
                )
            }
        }
        EdgeButton(
            onClick = {
                when {
                    e.checklist && e.isDone -> store.undo(e.order)
                    e.isTimed -> store.startWork(e.order)
                    e.checklist -> store.tickOff(e.order)
                    e.isDone || !e.canLog(e.nextWeight) -> onAdjust()
                    else -> store.log(e.order, e.nextWeight, e.nextReps)
                }
            },
            modifier = Modifier.align(Alignment.BottomCenter),
            buttonSize = EdgeButtonSize.Small,
            colors = if (e.isDone) ButtonDefaults.filledTonalButtonColors() else ButtonDefaults.buttonColors(),
        ) {
            Text(
                when {
                    e.checklist && e.isDone -> "Undo"
                    e.isDone -> "Extra set"
                    e.isTimed -> if (e.sets == 1) "Start" else "Start ${e.nextSet}/${e.setCount}"
                    e.checklist -> "Done"
                    else -> "Log ${e.nextSet}/${e.setCount}"
                },
            )
        }
    }
}

private fun header(workout: Workout, e: ExerciseInfo, now: Long): String {
    val waiting = workout.waiting(now)
    return when {
        waiting > 0 -> "$waiting waiting to send"
        workout.isFinished -> "All done · finish on phone"
        e.isDone -> "Done · ${e.order + 1}/${workout.exercises.size}"
        else -> "${e.sectionLabel} · ${e.order + 1}/${workout.exercises.size}"
    }
}

@Composable
fun timerColor(c: Countdown): Color = if (c.isWork) Brand.work else MaterialTheme.colorScheme.primary

@Composable
private fun Message(title: String, text: String) {
    Column(
        Modifier.fillMaxSize().background(Color.Black).padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            painterResource(R.drawable.ic_stat_wfit),
            contentDescription = null,
            modifier = Modifier.size(36.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.height(8.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Spacer(Modifier.height(4.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}
