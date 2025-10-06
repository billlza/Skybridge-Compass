package com.yunqiao.sinan.ui.component

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxScope.align
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.unit.dp
import com.yunqiao.sinan.shared.WeatherEffectType
import com.yunqiao.sinan.shared.WeatherVisualState
import kotlin.math.PI
import kotlin.math.coerceAtLeast
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.random.Random

@Composable
fun WeatherDynamicBackground(
    visualState: WeatherVisualState,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit
) {
    val gradientColors = remember(visualState.backgroundColors, visualState.renderingInfo) {
        val base = visualState.backgroundColors.ifEmpty { listOf(0xFF1E3C72, 0xFF2A5298) }
        val tone = visualState.renderingInfo.toneMapping.coerceIn(1f, 2.5f)
        base.map { colorValue ->
            val color = Color(colorValue)
            if (visualState.renderingInfo.hdrEnabled) {
                Color(
                    red = (color.red * tone).coerceIn(0f, 1f),
                    green = (color.green * tone).coerceIn(0f, 1f),
                    blue = (color.blue * tone).coerceIn(0f, 1f),
                    alpha = color.alpha
                )
            } else {
                color
            }
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(gradientColors))
    ) {
        WeatherBackLayer(visualState)

        Box(modifier = Modifier.fillMaxSize()) {
            content()
        }

        WeatherFrontLayer(visualState)
    }
}

@Composable
private fun WeatherBackLayer(visualState: WeatherVisualState) {
    when (visualState.effectType) {
        WeatherEffectType.SNOW -> SnowfallLayer(visualState, frontLayer = false)
        WeatherEffectType.RAIN -> RainLayer(visualState, storm = false)
        WeatherEffectType.STORM -> RainLayer(visualState, storm = true)
        WeatherEffectType.FOG -> FogLayer(visualState, backLayer = true)
        WeatherEffectType.CLEAR -> SunGlowLayer(visualState)
        WeatherEffectType.CLOUDY -> CloudSheenLayer(visualState)
    }
}

@Composable
private fun WeatherFrontLayer(visualState: WeatherVisualState) {
    if (visualState.mistAlpha > 0f) {
        FogLayer(visualState, backLayer = false)
    }

    when (visualState.effectType) {
        WeatherEffectType.SNOW -> {
            SnowfallLayer(visualState, frontLayer = true)
            SnowAccumulationOverlay(visualState)
        }
        WeatherEffectType.RAIN -> {
            RainLayer(visualState, storm = false, frontLayer = true)
            PuddleLayer(visualState)
        }
        WeatherEffectType.STORM -> {
            RainLayer(visualState, storm = true, frontLayer = true)
            PuddleLayer(visualState)
            StormFlashLayer(visualState)
        }
        WeatherEffectType.CLEAR -> LensFlareLayer(visualState)
        WeatherEffectType.CLOUDY -> CloudVeilFrontLayer(visualState)
        WeatherEffectType.FOG -> { /* fog already handled above */ }
    }

    if (visualState.renderingInfo.rayTracingEnabled) {
        RayTracedReflectionLayer(visualState)
    }
}

@Composable
private fun SnowfallLayer(
    visualState: WeatherVisualState,
    frontLayer: Boolean,
    modifier: Modifier = Modifier
) {
    val shading = visualState.renderingInfo.shadingBoost.coerceIn(1f, 1.8f)
    val density = (visualState.particleDensity * shading).coerceIn(0.2f, 2.2f)
    val particleCount = remember(density, frontLayer, shading) {
        val base = if (frontLayer) 140 else 100
        (base * density).roundToInt().coerceAtLeast(40)
    }
    val particles = remember(visualState.effectType, particleCount, frontLayer) {
        List(particleCount) { index ->
            SnowParticle(
                startX = Random(index * 41 + if (frontLayer) 7 else 13).nextFloat(),
                startY = Random(index * 53 + 19).nextFloat(),
                radius = if (frontLayer) Random(index * 67 + 5).nextFloat() * 4f + 2f else Random(index * 37 + 11).nextFloat() * 2f + 1f,
                sway = Random(index * 79 + 23).nextFloat() * PI.toFloat() * 2f,
                fallSpeed = if (frontLayer) 0.6f + density * 0.2f else 0.4f + density * 0.15f
            )
        }
    }
    val duration = remember(density) {
        (12000 / density.coerceAtLeast(0.25f)).roundToInt()
    }
    val transition = rememberInfiniteTransition(label = "snowfall_transition")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = duration, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "snowfall_progress"
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        particles.forEachIndexed { index, particle ->
            val yBase = (particle.startY + progress * particle.fallSpeed) % 1f
            val y = yBase * size.height
            val swayOffset = sin(progress * 6f + particle.sway + index * 0.12f) * if (frontLayer) 22f else 12f
            val x = (particle.startX * size.width + swayOffset + size.width) % size.width
            drawCircle(
                color = Color.White.copy(alpha = (if (frontLayer) 0.82f else 0.6f) * shading.coerceIn(1f, 1.5f)),
                radius = particle.radius,
                center = Offset(x, y)
            )
        }
    }
}

private data class SnowParticle(
    val startX: Float,
    val startY: Float,
    val radius: Float,
    val sway: Float,
    val fallSpeed: Float
)

@Composable
private fun RainLayer(
    visualState: WeatherVisualState,
    storm: Boolean,
    frontLayer: Boolean = false,
    modifier: Modifier = Modifier
) {
    val shading = visualState.renderingInfo.shadingBoost.coerceIn(1f, 1.6f)
    val density = ((visualState.particleDensity * shading) + if (storm) 0.2f else 0f).coerceIn(0.25f, 2.2f)
    val particleCount = remember(density, storm, frontLayer, shading) {
        val base = if (storm) 320 else 220
        val layerMultiplier = if (frontLayer) 1.2f else 1f
        (base * density * layerMultiplier).roundToInt().coerceAtLeast(120)
    }
    val particles = remember(visualState.effectType, particleCount, storm, frontLayer) {
        List(particleCount) { index ->
            RainParticle(
                startX = Random(index * 29 + 3).nextFloat(),
                startY = Random(index * 47 + 17).nextFloat(),
                length = if (frontLayer) Random(index * 31 + 9).nextFloat() * 32f + 12f else Random(index * 37 + 11).nextFloat() * 20f + 8f,
                speed = if (storm) 1.6f else 1.2f,
                thickness = if (storm) 2.4f * shading else 1.6f * shading
            )
        }
    }
    val duration = remember(density, storm) {
        (4200 / (density + if (storm) 0.4f else 0f)).roundToInt()
    }
    val transition = rememberInfiniteTransition(label = "rain_transition")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = duration, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "rain_progress"
    )

    Canvas(modifier = modifier.fillMaxSize()) {
        particles.forEachIndexed { index, particle ->
            val yBase = (particle.startY + progress * particle.speed + index * 0.002f) % 1f
            val start = Offset(particle.startX * size.width, yBase * size.height)
            val end = Offset(start.x - particle.length * 0.3f, start.y + particle.length)
            drawLine(
                color = Color.White.copy(alpha = (if (frontLayer) 0.75f else 0.4f) * shading.coerceIn(1f, 1.4f)),
                start = start,
                end = end,
                strokeWidth = particle.thickness,
                cap = StrokeCap.Round
            )
        }
    }
}

private data class RainParticle(
    val startX: Float,
    val startY: Float,
    val length: Float,
    val speed: Float,
    val thickness: Float
)

@Composable
private fun FogLayer(visualState: WeatherVisualState, backLayer: Boolean) {
    val alpha = if (backLayer) visualState.mistAlpha * 0.6f else visualState.mistAlpha
    if (alpha <= 0f) return

    val topColor = if (backLayer) Color.White.copy(alpha = alpha * 0.25f) else Color.White.copy(alpha = alpha * 0.35f)
    val bottomColor = if (backLayer) Color.White.copy(alpha = alpha * 0.6f) else Color.White.copy(alpha = alpha * 0.75f)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(topColor, bottomColor)
                )
            )
    )
}

@Composable
private fun PuddleLayer(visualState: WeatherVisualState) {
    if (visualState.puddleLevel <= 0f) return

    val puddleHeight = remember(visualState.puddleLevel) {
        (120 * visualState.puddleLevel.coerceIn(0.2f, 0.8f)).roundToInt().dp
    }

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(puddleHeight)
            .align(Alignment.BottomCenter)
    ) {
        val puddleTop = size.height * (1f - visualState.puddleLevel.coerceIn(0.2f, 0.85f))
        drawRect(
            brush = Brush.verticalGradient(
                colors = listOf(
                    Color(0x803B8AC4),
                    Color(0x8036758E),
                    Color(0x66305063)
                ),
                startY = puddleTop,
                endY = size.height
            ),
            topLeft = Offset.Zero,
            size = Size(size.width, size.height)
        )
        drawIntoCanvas { canvas ->
            val ripplePaint = androidx.compose.ui.graphics.Paint().apply {
                color = Color.White.copy(alpha = 0.18f)
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(12f, 18f), 0f)
                strokeWidth = 2f
                style = androidx.compose.ui.graphics.PaintingStyle.Stroke
            }
            val rippleCount = 5
            repeat(rippleCount) { index ->
                val fraction = index / rippleCount.toFloat()
                val radius = size.width * (0.25f + fraction * 0.35f)
                canvas.drawCircle(
                    center = Offset(size.width * 0.5f, size.height * 0.85f),
                    radius = radius,
                    paint = ripplePaint
                )
            }
        }
    }
}

@Composable
private fun SnowAccumulationOverlay(visualState: WeatherVisualState) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val bandCount = 3
        val bandHeight = size.height * 0.018f
        repeat(bandCount) { index ->
            val y = size.height * (0.25f + index * 0.22f)
            drawRoundRect(
                color = Color.White.copy(alpha = 0.28f + index * 0.08f),
                topLeft = Offset(size.width * 0.08f, y),
                size = Size(size.width * 0.84f, bandHeight),
                cornerRadius = CornerRadius(bandHeight, bandHeight)
            )
        }
    }
}

@Composable
private fun SunGlowLayer(visualState: WeatherVisualState) {
    if (visualState.isNight) return

    Canvas(modifier = Modifier.fillMaxSize()) {
        val radius = min(size.width, size.height) * 0.7f
        val glowStrength = (visualState.highlightStrength.coerceIn(0.2f, 0.9f) * visualState.renderingInfo.shadingBoost.coerceIn(1f, 1.5f))
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(
                    Color.White.copy(alpha = 0.35f * glowStrength.coerceIn(0.2f, 1.2f)),
                    Color.Transparent
                ),
                center = Offset(size.width * 0.82f, size.height * 0.18f),
                radius = radius
            ),
            radius = radius,
            center = Offset(size.width * 0.82f, size.height * 0.18f)
        )
    }
}

@Composable
private fun LensFlareLayer(visualState: WeatherVisualState) {
    if (visualState.isNight) return

    val accent = Color(visualState.accentColor)
    val intensity = visualState.renderingInfo.shadingBoost.coerceIn(1f, 1.6f)
    Canvas(modifier = Modifier.fillMaxSize()) {
        val center = Offset(size.width * 0.8f, size.height * 0.2f)
        val radii = listOf(12f, 36f, 64f, 120f)
        radii.forEachIndexed { index, radius ->
            drawCircle(
                color = accent.copy(alpha = (0.25f - index * 0.04f) * intensity),
                radius = radius,
                center = center
            )
        }
    }
}

@Composable
private fun StormFlashLayer(visualState: WeatherVisualState) {
    val transition = rememberInfiniteTransition(label = "storm_flash")
    val flash by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 3600, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "storm_flash_progress"
    )

    val intensity = if (flash > 0.92f) (flash - 0.92f) * 12f else 0f
    if (intensity <= 0f) return

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.White.copy(alpha = (0.18f * intensity).coerceIn(0f, 0.25f)))
    )
}

@Composable
private fun CloudSheenLayer(visualState: WeatherVisualState) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val gradient = Brush.verticalGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.08f),
                Color.White.copy(alpha = 0.18f),
                Color.Transparent
            )
        )
        drawRect(gradient, size = size)
    }
}

@Composable
private fun CloudVeilFrontLayer(visualState: WeatherVisualState) {
    Canvas(modifier = Modifier.fillMaxSize()) {
        val gradient = Brush.verticalGradient(
            colors = listOf(
                Color.White.copy(alpha = 0.12f),
                Color.Transparent,
                Color(0x40FFFFFF)
            )
        )
        drawRect(gradient, size = size)
    }
}

@Composable
private fun RayTracedReflectionLayer(visualState: WeatherVisualState) {
    val reflection = visualState.renderingInfo.reflectionStrength.coerceIn(1f, 1.6f)
    val accent = Color(visualState.accentColor)
    Canvas(modifier = Modifier.fillMaxSize()) {
        val startY = size.height * 0.55f
        val gradient = Brush.verticalGradient(
            colors = listOf(
                accent.copy(alpha = 0.16f * reflection),
                accent.copy(alpha = 0.08f * reflection),
                Color.Transparent
            ),
            startY = startY,
            endY = size.height
        )
        drawRect(
            brush = gradient,
            topLeft = Offset(0f, startY),
            size = Size(size.width, size.height - startY)
        )
        val sheenAlpha = 0.12f * reflection
        drawLine(
            color = Color.White.copy(alpha = sheenAlpha),
            start = Offset(size.width * 0.15f, size.height * 0.78f),
            end = Offset(size.width * 0.85f, size.height * 0.72f),
            strokeWidth = 6f,
            cap = StrokeCap.Round
        )
        drawLine(
            color = Color.White.copy(alpha = sheenAlpha * 0.8f),
            start = Offset(size.width * 0.2f, size.height * 0.88f),
            end = Offset(size.width * 0.8f, size.height * 0.86f),
            strokeWidth = 4f,
            cap = StrokeCap.Round
        )
    }
}
