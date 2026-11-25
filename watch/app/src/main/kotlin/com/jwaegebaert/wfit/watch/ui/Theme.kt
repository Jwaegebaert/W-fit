package com.jwaegebaert.wfit.watch.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme

/** Same palette as the phone app's dark theme (`app/lib/core/theme.dart`). */
object Brand {
    val mint = Color(0xFF5FD6BF)
    val work = Color(0xFFEF6C4D)
    val gold = Color(0xFFE8A93A)
}

private val scheme = ColorScheme(
    primary = Brand.mint,
    onPrimary = Color(0xFF00382F),
    primaryContainer = Color(0xFF0A5148),
    onPrimaryContainer = Color(0xFFC2EFE5),
    tertiary = Color(0xFFF2BE5C),
    onTertiary = Color(0xFF422C00),
    surfaceContainerLow = Color(0xFF19231F),
    surfaceContainer = Color(0xFF232E2A),
    surfaceContainerHigh = Color(0xFF2E3935),
    onSurface = Color(0xFFE6EEEB),
    onSurfaceVariant = Color(0xFFB4C2BD),
    background = Color.Black,
    onBackground = Color(0xFFE6EEEB),
)

@Composable
fun WfitTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = scheme, content = content)
