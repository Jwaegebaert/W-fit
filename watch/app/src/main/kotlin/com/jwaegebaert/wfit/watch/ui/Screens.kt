package com.jwaegebaert.wfit.watch.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.ButtonDefaults

import androidx.wear.compose.material3.CompactButton
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.FilledTonalIconButton
import androidx.wear.compose.material3.MaterialTheme

import androidx.wear.compose.material3.Text
import com.jwaegebaert.wfit.watch.core.Countdown
import com.jwaegebaert.wfit.watch.core.ExerciseInfo
import com.jwaegebaert.wfit.watch.core.Workout
import com.jwaegebaert.wfit.watch.core.formatClock
import com.jwaegebaert.wfit.watch.core.formatKg
import com.jwaegebaert.wfit.watch.core.setSummary
import com.jwaegebaert.wfit.watch.link.WorkoutStore
import java.text.DateFormat
import java.util.Date
import kotlin.math.abs

@Composable
fun TimerScreen(store: WorkoutStore, workout: Workout, running: Countdown, now: Long, bpm: Int?) {
    val color = timerColor(running)
    val next = workout.focused
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        // Drawn by hand: the library's ring animates every change and lags behind a countdown.
        Canvas(Modifier.fillMaxSize().padding(5.dp)) {
            val stroke = Stroke(6.dp.toPx(), cap = StrokeCap.Round)
            drawCircle(color.copy(alpha = 0.2f), style = stroke)
            drawArc(color, -90f, 360f * running.fractionLeft(now), useCenter = false, style = stroke)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(horizontal = 24.dp)) {
            val config = LocalConfiguration.current
            if (bpm != null && !(running.isWork && config.screenHeightDp / config.fontScale < 210)) {
                Text(
                    heartLabel(bpm),
                    modifier = Modifier.semantics { contentDescription = "Heart rate $bpm" },
                    style = MaterialTheme.typography.labelSmall,
                    color = Brand.work,
                )
            }
            Text(
                running.phaseAt(now)?.label.orEmpty(),
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                formatClock(running.remaining(now)),
                style = MaterialTheme.typography.numeralMedium,
                color = color,
                fontWeight = FontWeight.Bold,
            )
            if (!running.isWork && next != null && !next.isDone) {
                Text(
                    "${next.name}\n${next.nextSet}/${next.setCount} · ${next.setSummary()}",
                    style = MaterialTheme.typography.bodyExtraSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(8.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RoundButton("−15", "15 seconds less", Modifier.weight(1f)) { store.extendTimer(-15) }
                RoundButton(
                    if (running.isWork) "Stop" else "Skip",
                    if (running.isWork) "Stop without logging" else "Skip rest",
                    Modifier.weight(1.25f),
                ) { store.stopTimer() }
                RoundButton("+15", "15 seconds more", Modifier.weight(1f)) { store.extendTimer(15) }
            }
            if (running.isWork) {
                Spacer(Modifier.height(4.dp))
                CompactButton(onClick = { store.finishWork() }, label = { Text("Log now") })
            }
        }
    }
}

/** The selector keeps the heart a plain character in the text colour instead of an emoji. */
fun heartLabel(bpm: Int): String = "♥${Char(0xFE0E)} $bpm"

@Composable
private fun RoundButton(label: String, description: String, modifier: Modifier, onClick: () -> Unit) {
    FilledTonalIconButton(
        onClick = onClick,
        modifier = modifier.height(42.dp).semantics { contentDescription = description },
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false)
    }
}

/** Reps and weight of the next set. The bezel changes the highlighted value. */
@Composable
fun AdjustScreen(e: ExerciseInfo, onLog: (Double?, Int) -> Unit, onUndo: () -> Unit) {
    var reps by remember { mutableIntStateOf(e.nextReps) }
    var weight by remember { mutableStateOf(e.nextWeight) }
    val hasWeight = e.weightLabel != null
    var weightSelected by remember { mutableStateOf(hasWeight) }
    val haptics = LocalHapticFeedback.current
    val focus = remember { FocusRequester() }
    var scrolled by remember { mutableFloatStateOf(0f) }

    fun change(up: Boolean) {
        val sign = if (up) 1 else -1
        if (weightSelected) {
            weight = maxOf(0.0, (weight ?: 0.0) + sign * e.step)
        } else {
            reps = maxOf(0, reps + sign)
        }
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
    }

    LaunchedEffect(Unit) { focus.requestFocus() }
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onRotaryScrollEvent { event ->
                scrolled += event.verticalScrollPixels
                while (abs(scrolled) >= ROTARY_STEP) {
                    change(up = scrolled > 0)
                    scrolled -= if (scrolled > 0) ROTARY_STEP else -ROTARY_STEP
                }
                true
            }
            .focusRequester(focus)
            .focusable(),
    ) {
        Column(
            Modifier.fillMaxSize().padding(top = 8.dp, bottom = 60.dp),
            verticalArrangement = Arrangement.SpaceEvenly,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val undo = e.undoable
            Text(
                if (undo != null) "Undo set ${undo.set}" else "Set ${e.nextSet}",
                modifier = if (undo == null) {
                    Modifier
                } else {
                    Modifier
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceContainer)
                        .clickable(onClick = onUndo)
                        .padding(horizontal = 14.dp, vertical = 6.dp)
                },
                style = MaterialTheme.typography.labelMedium,
                color = if (undo != null) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.primary,
            )
            Stepper("$reps", if (e.perSide) "reps / side" else "reps", selected = !weightSelected) { up ->
                weightSelected = false
                if (up != null) change(up)
            }
            if (hasWeight) {
                Stepper(weight?.let(::formatKg) ?: "–", e.weightLabel.orEmpty(), selected = weightSelected) { up ->
                    weightSelected = true
                    if (up != null) change(up)
                }
            }
        }
        EdgeButton(
            onClick = { onLog(weight, reps) },
            modifier = Modifier.align(Alignment.BottomCenter),
            buttonSize = EdgeButtonSize.Small,
            enabled = e.canLog(weight),
        ) { Text(if (e.canLog(weight)) "Log ${e.nextSet}/${maxOf(e.setCount, e.nextSet)}" else "Set weight") }
    }
}

private const val ROTARY_STEP = 48f

/** [onChange] gets true for more, false for less and null when the value itself is tapped. */
@Composable
private fun Stepper(value: String, label: String, selected: Boolean, onChange: (Boolean?) -> Unit) {
    val width = (LocalConfiguration.current.screenWidthDp * 0.36f).dp
    Row(verticalAlignment = Alignment.CenterVertically) {
        FilledTonalIconButton(onClick = { onChange(false) }, modifier = Modifier.size(44.dp).semantics { contentDescription = "Less $label" }) {
            Text("−", style = MaterialTheme.typography.titleMedium)
        }
        Column(
            Modifier.width(width).clickable { onChange(null) },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                value,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            Text(label, style = MaterialTheme.typography.bodyExtraSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        FilledTonalIconButton(onClick = { onChange(true) }, modifier = Modifier.size(44.dp).semantics { contentDescription = "More $label" }) {
            Text("+", style = MaterialTheme.typography.titleMedium)
        }
    }
}

/** Wrist down: drawn about once a minute, so it shows when the countdown ends instead of what is left. */
@Composable
fun AmbientScreen(workout: Workout, running: Countdown?, now: Long) {
    val e = workout.focused
    Column(
        Modifier.fillMaxSize().background(Color.Black).padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val time = DateFormat.getTimeInstance(DateFormat.SHORT)
        Text(time.format(Date(now)), style = MaterialTheme.typography.titleLarge, color = Color.White)
        val phase = running?.phaseAt(now)
        if (phase != null) {
            Text(
                "${phase.label}\nuntil ${DateFormat.getTimeInstance(DateFormat.MEDIUM).format(Date(phase.endsAt))}",
                style = MaterialTheme.typography.bodyMedium,
                color = Color.LightGray,
                textAlign = TextAlign.Center,
            )
        }
        if (e != null && workout.isActive(now)) {
            Spacer(Modifier.height(6.dp))
            Text(
                "${e.name}\n" + if (e.isDone) "Done" else "${e.nextSet}/${e.setCount} · ${e.setSummary()}",
                style = MaterialTheme.typography.bodySmall,
                color = Color.LightGray,
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
