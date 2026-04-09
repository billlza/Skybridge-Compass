package com.skybridge.compass.android.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import kotlin.random.Random

/**
 * Lightweight animated starfield background.
 * - No blur / no images (GPU-friendly)
 * - Deterministic stars per composition (seeded)
 */
@Composable
fun StarfieldBackground(
    modifier: Modifier = Modifier,
    starCount: Int = 140,
    seed: Int = 42
) {
    val stars = remember(seed, starCount) {
        val r = Random(seed)
        List(starCount.coerceAtLeast(0)) {
            Star(
                x = r.nextFloat(),
                y = r.nextFloat(),
                radius = r.nextFloat().let { 0.6f + it * 1.6f },
                baseAlpha = r.nextFloat().let { 0.15f + it * 0.55f },
                phase = r.nextFloat()
            )
        }
    }

    val transition = rememberInfiniteTransition(label = "starfield")
    val twinkle by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2600),
            repeatMode = RepeatMode.Reverse
        ),
        label = "twinkle"
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        // Background gradient (deep space)
        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(
                    Color(0xFF1A2233),
                    Color(0xFF0B1020)
                ),
                center = center,
                radius = size.minDimension * 0.9f
            )
        )

        // Stars
        stars.forEach { s ->
            val wave = kotlin.math.sin(((twinkle + s.phase) * 6.2831f).toDouble()).toFloat()
            val a = (s.baseAlpha + (wave * 0.18f))
                .coerceIn(0.05f, 0.95f)
            drawCircle(
                color = Color.White.copy(alpha = a),
                radius = s.radius,
                center = Offset(s.x * size.width, s.y * size.height)
            )
        }
    }
}

private data class Star(
    val x: Float,
    val y: Float,
    val radius: Float,
    val baseAlpha: Float,
    val phase: Float
)


