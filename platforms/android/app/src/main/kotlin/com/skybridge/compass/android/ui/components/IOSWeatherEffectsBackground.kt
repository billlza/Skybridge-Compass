package com.skybridge.compass.android.ui.components

import android.os.PowerManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.weather.WeatherCondition
import com.skybridge.compass.android.weather.WeatherRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import javax.inject.Inject
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

enum class IOSWeatherCondition {
    Clear,
    Cloudy,
    Rainy,
    Snowy,
    Foggy,
    Haze,
    Stormy,
    Unknown
}

/**
 * 1:1 port of iOS QuantumGlassBackground.
 *
 * All layers rendered in a single Canvas so we can use the correct
 * blend modes: Screen for fluid blobs, Overlay for frosted tint.
 * Gaussian blur of the blob circles is approximated with soft radial
 * gradients (same visual result, avoids cross-layer compositing issues).
 */
@Composable
fun IOSDashboardAnimatedBackground(
    condition: IOSWeatherCondition,
    isActive: Boolean,
    modifier: Modifier = Modifier
) {
    val minimumInterval = rememberWeatherEffectsMinimumIntervalSeconds()

    var timelineSeconds by remember { mutableDoubleStateOf(0.0) }
    val minimumIntervalNs = (minimumInterval * 1_000_000_000.0).toLong().coerceAtLeast(1L)

    LaunchedEffect(minimumIntervalNs) {
        var lastTick = 0L
        while (true) {
            withFrameNanos { frameNs ->
                if (lastTick == 0L || frameNs - lastTick >= minimumIntervalNs) {
                    timelineSeconds = frameNs / 1_000_000_000.0
                    lastTick = frameNs
                }
            }
        }
    }

    // ── iOS QuantumFluidLayer blobs ──────────────────────────────────
    val blobs = remember {
        listOf(
            FluidBlob(Color(0xFF1A4DBF), 123.4, 567.8, 0.70f, 0.15),  // blue
            FluidBlob(Color(0xFF591AA6), 234.5, 678.9, 0.60f, 0.12),  // purple
            FluidBlob(Color(0xFF1A738C), 345.6, 789.0, 0.55f, 0.18),  // cyan
            FluidBlob(Color(0xFF8C2673), 456.7, 890.1, 0.45f, 0.14),  // magenta
            FluidBlob(Color(0xFF263399), 567.8, 123.4, 0.50f, 0.10)   // indigo
        )
    }

    // ── iOS QuantumStarLayer stars (seeded like iOS: seed = i * 73) ──
    val stars = remember {
        List(60) { i ->
            val rng = IosSeedRNG(i * 73)
            val x = rng.next()
            val y = rng.next()
            val r = rng.nextIn(0.6, 1.8).toFloat()
            val twinkleSpeed = rng.nextIn(0.8, 3.0)
            val phase = rng.nextIn(0.0, Math.PI * 2)
            val brightnessScale = rng.nextIn(0.4, 1.0)
            val tint = rng.next()
            val color = when {
                tint < 0.15 -> Color.Cyan.copy(alpha = 0.9f)
                tint < 0.30 -> Color(red = 0.7f, green = 0.8f, blue = 1.0f)
                else -> Color.White
            }
            StarParticle(x, y, r, twinkleSpeed, phase, brightnessScale, color)
        }
    }

    // ── Weather particle pools ──────────────────────────────────────
    val clearParticles = remember {
        val rng = Random(0x5151_0001)
        List(120) {
            ClearParticle(
                rng.nextDouble(), rng.nextDouble(),
                rng.nextDouble(0.02, 0.10), rng.nextDouble(0.0, 2 * Math.PI),
                rng.nextDouble(0.8, 2.0).toFloat(),
                rng.nextDouble(-0.08, 0.08), rng.nextDouble(0.6, 1.4)
            )
        }
    }
    val cloudyLayers = remember {
        listOf(CloudLayer(0.02, 0f, 0.35f), CloudLayer(0.03, 40f, 0.27f), CloudLayer(0.04, 80f, 0.19f))
    }
    val rainDrops = remember { buildRainDrops(Random(0xA11A_1001), 360, 1.0..2.1, 14.0..40.0) }
    val stormDrops = remember { buildRainDrops(Random(0xA11A_1002), 520, 1.6..2.6, 20.0..55.0) }
    val snowFlakes = remember {
        val rng = Random(0x5A0F_0001)
        List(260) {
            SnowFlake(
                rng.nextDouble(), rng.nextDouble(),
                rng.nextDouble(0.10, 0.32), rng.nextDouble(1.2, 3.2).toFloat(),
                rng.nextDouble(0.18, 0.60), rng.nextDouble(0.10, 0.22),
                rng.nextDouble(0.0, 2 * Math.PI)
            )
        }
    }
    val fogPuffs = remember { generateFogPuffs(0xF06F_0001) }
    val hazePuffs = remember { generateFogPuffs(0xBEEF_0001) }

    // ── Single Canvas – all layers with correct blend modes ─────────
    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val minDim = min(w, h)
        val blurExtentPx = 80.dp.toPx()

        // ① Deep-space gradient  (iOS: topLeading → bottomTrailing)
        drawRect(
            brush = Brush.linearGradient(
                colors = listOf(
                    Color(0xFF0A0F2E),   // Color(red:0.04, green:0.06, blue:0.18)
                    Color(0xFF0F0A29),   // Color(red:0.06, green:0.04, blue:0.16)
                    Color(0xFF08081A)    // Color(red:0.03, green:0.03, blue:0.10)
                ),
                start = Offset.Zero,
                end = Offset(w, h)
            )
        )

        // ② Quantum fluid blobs  (iOS: .blendMode(.screen), .opacity(0.82), .blur(80))
        drawQuantumFluidBlobs(blobs, timelineSeconds, blurExtentPx, minDim)

        // ③ Quantum stars  (iOS: .opacity(0.45))
        drawQuantumStars(stars, timelineSeconds)

        // ④ Frosted overlay  (iOS: Color.white.opacity(0.06), .blendMode(.overlay))
        drawRect(
            color = Color.White,
            alpha = 0.06f,
            blendMode = BlendMode.Overlay
        )

        // ⑤ Weather effects
        if (isActive) {
            drawRect(
                brush = Brush.linearGradient(
                    colors = tintColorsFor(condition),
                    start = Offset.Zero,
                    end = Offset(w, h)
                ),
                alpha = 0.40f
            )
            when (condition) {
                IOSWeatherCondition.Clear -> drawClearSky(clearParticles, timelineSeconds)
                IOSWeatherCondition.Cloudy -> drawCloudySky(cloudyLayers, timelineSeconds)
                IOSWeatherCondition.Rainy -> drawRain(rainDrops, timelineSeconds, false)
                IOSWeatherCondition.Snowy -> drawSnow(snowFlakes, timelineSeconds)
                IOSWeatherCondition.Foggy -> drawFog(fogPuffs, timelineSeconds, Color.White)
                IOSWeatherCondition.Haze -> drawFog(hazePuffs, timelineSeconds, Color(0xFFF2DBB8))
                IOSWeatherCondition.Stormy -> drawRain(stormDrops, timelineSeconds, true)
                IOSWeatherCondition.Unknown -> Unit
            }
        }
    }
}

// =====================================================================
// ② Quantum Fluid Blobs – Screen blend + radial gradient ≈ blur(80)
// =====================================================================

private fun DrawScope.drawQuantumFluidBlobs(
    blobs: List<FluidBlob>,
    timeSeconds: Double,
    blurExtentPx: Float,
    minDim: Float
) {
    for (blob in blobs) {
        val xProgress = (sin(timeSeconds * blob.speed + blob.xSeed) + 1.0) / 2.0
        val yProgress = (cos(timeSeconds * blob.speed * 0.8 + blob.ySeed) + 1.0) / 2.0
        val x = (size.width * 0.05f + xProgress.toFloat() * size.width * 0.9f)
        val y = (size.height * 0.05f + yProgress.toFloat() * size.height * 0.9f)
        val blobRadius = minDim * blob.sizeScale / 2f
        val breathe = (0.6 + 0.4 * sin(timeSeconds * 0.4 + blob.xSeed * 0.01))
            .toFloat().coerceIn(0f, 1f)

        val totalRadius = blobRadius + blurExtentPx * 1.6f
        val edgeRatio = (blobRadius / totalRadius).coerceIn(0.1f, 0.85f)

        drawCircle(
            brush = Brush.radialGradient(
                colorStops = arrayOf(
                    0.0f to blob.color,
                    edgeRatio * 0.55f to blob.color,
                    edgeRatio to blob.color.copy(alpha = 0.50f),
                    edgeRatio + (1f - edgeRatio) * 0.35f to blob.color.copy(alpha = 0.15f),
                    edgeRatio + (1f - edgeRatio) * 0.70f to blob.color.copy(alpha = 0.03f),
                    1.0f to Color.Transparent
                ),
                center = Offset(x, y),
                radius = totalRadius
            ),
            radius = totalRadius,
            center = Offset(x, y),
            blendMode = BlendMode.Screen,
            alpha = 0.82f * breathe
        )
    }
}

// =====================================================================
// ③ Quantum Stars
// =====================================================================

private fun DrawScope.drawQuantumStars(
    stars: List<StarParticle>,
    timeSeconds: Double
) {
    for (star in stars) {
        val x = star.x.toFloat() * size.width
        val y = star.y.toFloat() * size.height
        val alpha = ((0.3 + 0.5 * sin(timeSeconds * star.twinkleSpeed + star.phase))
                * star.brightnessScale).toFloat().coerceIn(0f, 1f)
        drawCircle(
            color = star.color,
            radius = star.radius,
            center = Offset(x, y),
            alpha = 0.45f * alpha
        )
    }
}

// =====================================================================
// ⑤ Weather effect drawing  (unchanged rendering logic from iOS port)
// =====================================================================

private fun DrawScope.drawClearSky(particles: List<ClearParticle>, t: Double) {
    particles.forEach { p ->
        val x = ((p.originX + sin(t * p.speed + p.phase) * 0.05) * size.width).toFloat()
        val y = ((p.originY + cos(t * p.speed + p.phase) * 0.05) * size.height).toFloat()
        val tw = (sin(t * p.twinkle + p.phase) * 0.5 + 0.5).toFloat()
        val a = (0.20f + 0.18f * tw).coerceIn(0f, 1f)
        drawCircle(
            color = Color.hsl(
                hue = (216f + (p.hueShift * 360f).toFloat()).coerceIn(0f, 360f),
                saturation = 0.35f, lightness = 0.95f, alpha = a
            ),
            radius = p.size, center = Offset(x, y)
        )
    }
}

private fun DrawScope.drawCloudySky(layers: List<CloudLayer>, t: Double) {
    layers.forEach { layer ->
        val progress = ((t * layer.speed) % 1.0).toFloat()
        drawRoundRect(
            color = Color.White.copy(alpha = layer.alpha),
            topLeft = Offset(-size.width + progress * size.width, layer.yOffsetPx),
            size = Size(size.width * 2f, size.height * 0.7f),
            cornerRadius = CornerRadius(220f, 220f)
        )
    }
}

private fun DrawScope.drawRain(drops: List<RainDrop>, t: Double, storm: Boolean) {
    val wind = sin(t * 0.15).toFloat() * if (storm) 0.35f else 0.20f
    val baseAlpha = if (storm) 0.26f else 0.20f
    drops.forEach { d ->
        val px = ((d.x + (wind + d.drift.toFloat()) * 0.04f) * size.width).toFloat()
        val py = ((((d.y + t * d.speed * 0.10) % 1.0) * size.height)).toFloat()
        drawLine(
            color = Color.White.copy(alpha = baseAlpha * d.alpha.toFloat()),
            start = Offset(px, py),
            end = Offset(px + wind * d.length * 0.25f, py + d.length),
            strokeWidth = d.width, cap = StrokeCap.Round
        )
    }
    if (storm) {
        val flash = max(0.0, sin(t * 1.6) - 0.82) * 2.0
        if (flash > 0.0) drawRect(color = Color.White.copy(alpha = (0.12 * flash).toFloat()))
    }
}

private fun DrawScope.drawSnow(flakes: List<SnowFlake>, t: Double) {
    flakes.forEach { f ->
        val x = ((f.x + sin(t * f.sway + f.phase) * 0.03) * size.width).toFloat()
        val y = ((((f.y + t * f.speed) % 1.0) * size.height)).toFloat()
        drawCircle(
            color = Color.White.copy(alpha = f.alpha.toFloat()),
            radius = f.size, center = Offset(x, y), style = Stroke(0f)
        )
    }
}

private fun DrawScope.drawFog(puffs: List<FogPuff>, t: Double, tint: Color) {
    puffs.forEach { p ->
        val x = ((p.originX + sin(t * p.speed + p.phase) * 0.06) * size.width).toFloat()
        val y = ((p.originY + cos(t * p.speed + p.phase) * 0.06) * size.height).toFloat()
        val r = (p.radius * (0.92 + 0.08 * sin(t * p.speed + p.phase))).toFloat()
        drawCircle(color = tint.copy(alpha = p.alpha.toFloat()), radius = r, center = Offset(x, y))
    }
}

// =====================================================================
// Weather tint palette  (matches iOS WeatherEffectsTintGradient)
// =====================================================================

private fun tintColorsFor(c: IOSWeatherCondition): List<Color> = when (c) {
    IOSWeatherCondition.Clear -> listOf(Color(0x59FFAA33), Color(0x2EFFE066))
    IOSWeatherCondition.Cloudy -> listOf(Color(0x40A0A4B0), Color(0x1A70A0D0))
    IOSWeatherCondition.Rainy -> listOf(Color(0x423B82F6), Color(0x1F22D3EE))
    IOSWeatherCondition.Snowy -> listOf(Color(0x2ECDEAFB), Color(0x1AF5F8FF))
    IOSWeatherCondition.Foggy -> listOf(Color(0x299AA0AA), Color(0x14EEF2F7))
    IOSWeatherCondition.Haze -> listOf(Color(0x24EFA041), Color(0x24A0A7B5))
    IOSWeatherCondition.Stormy -> listOf(Color(0x384B2DAA), Color(0x2E3366CC))
    IOSWeatherCondition.Unknown -> listOf(Color(0x1A9AA0AA), Color.Transparent)
}

// =====================================================================
// Frame-rate policy  (matches iOS WeatherEffectsFrameRatePolicy)
// =====================================================================

@Composable
private fun rememberWeatherEffectsMinimumIntervalSeconds(): Double {
    val context = LocalContext.current
    val view = LocalView.current
    return remember(context, view.display?.refreshRate) {
        val pm = context.getSystemService(PowerManager::class.java)
        val targetFps = if (pm?.isPowerSaveMode == true) 24.0
        else min(60.0, (view.display?.refreshRate ?: 60f).toDouble())
        1.0 / max(10.0, targetFps)
    }
}

// =====================================================================
// iOS-matching seeded RNG  (reproduces QuantumStarLayer.SeededRNG)
// =====================================================================

private class IosSeedRNG(seed: Int) {
    private var state: ULong = seed.toULong()
    fun next(): Double {
        state = state * 6364136223846793005uL + 1uL
        return state.toDouble() / ULong.MAX_VALUE.toDouble()
    }
    fun nextIn(lo: Double, hi: Double): Double = lo + next() * (hi - lo)
}

// =====================================================================
// Data classes
// =====================================================================

private data class FluidBlob(val color: Color, val xSeed: Double, val ySeed: Double, val sizeScale: Float, val speed: Double)
private data class StarParticle(val x: Double, val y: Double, val radius: Float, val twinkleSpeed: Double, val phase: Double, val brightnessScale: Double, val color: Color)
private data class ClearParticle(val originX: Double, val originY: Double, val speed: Double, val phase: Double, val size: Float, val hueShift: Double, val twinkle: Double)
private data class CloudLayer(val speed: Double, val yOffsetPx: Float, val alpha: Float)
private data class RainDrop(val x: Double, val y: Double, val speed: Double, val length: Float, val width: Float, val alpha: Double, val drift: Double)
private data class SnowFlake(val x: Double, val y: Double, val speed: Double, val size: Float, val sway: Double, val alpha: Double, val phase: Double)
private data class FogPuff(val originX: Double, val originY: Double, val radius: Double, val speed: Double, val phase: Double, val alpha: Double)

private fun buildRainDrops(rng: Random, count: Int, speedRange: ClosedRange<Double>, lenRange: ClosedRange<Double>): List<RainDrop> =
    List(count) {
        RainDrop(
            rng.nextDouble(), rng.nextDouble(),
            rng.nextDouble(speedRange.start, speedRange.endInclusive),
            rng.nextDouble(lenRange.start, lenRange.endInclusive).toFloat(),
            rng.nextDouble(0.7, 1.4).toFloat(),
            rng.nextDouble(0.12, 0.26),
            rng.nextDouble(-0.08, 0.08)
        )
    }

private fun generateFogPuffs(seed: Long): List<FogPuff> {
    val r = SplitMix64(seed.toULong())
    return List(46) {
        FogPuff(r.nextDouble(0.0, 1.0), r.nextDouble(0.0, 1.0), r.nextDouble(140.0, 340.0), r.nextDouble(0.02, 0.10), r.nextDouble(0.0, 2 * Math.PI), r.nextDouble(0.05, 0.12))
    }
}

private class SplitMix64(seed: ULong) {
    private var state: ULong = if (seed == 0UL) 0xDEAD_BEEFuL else seed
    private fun nextULong(): ULong { state += 0x9E3779B97F4A7C15uL; var z = state; z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL; z = (z xor (z shr 27)) * 0x94D049BB133111EBuL; return z xor (z shr 31) }
    fun nextDouble(lo: Double, hi: Double): Double = lo + (hi - lo) * nextULong().toDouble() / ULong.MAX_VALUE.toDouble()
}

// =====================================================================
// ViewModel  (maps HardwareMonitor quality → weather condition)
// =====================================================================

data class IOSBackgroundEffectsUiState(
    val condition: IOSWeatherCondition = IOSWeatherCondition.Unknown,
    val isActive: Boolean = true
)

@HiltViewModel
class IOSBackgroundEffectsViewModel @Inject constructor(
    private val weatherRepository: WeatherRepository
) : ViewModel() {
    var uiState by mutableStateOf(IOSBackgroundEffectsUiState())
        private set

    init {
        weatherRepository.observeWeather()
            .onEach { weatherState ->
                uiState = uiState.copy(
                    condition = weatherState.weather?.condition.toBackgroundCondition()
                )
            }
            .launchIn(viewModelScope)
        weatherRepository.refreshWeather()
    }
}

private fun WeatherCondition?.toBackgroundCondition(): IOSWeatherCondition = when (this) {
    WeatherCondition.CLEAR -> IOSWeatherCondition.Clear
    WeatherCondition.PARTLY_CLOUDY,
    WeatherCondition.CLOUDY -> IOSWeatherCondition.Cloudy
    WeatherCondition.RAINY -> IOSWeatherCondition.Rainy
    WeatherCondition.SNOWY -> IOSWeatherCondition.Snowy
    WeatherCondition.FOGGY -> IOSWeatherCondition.Foggy
    WeatherCondition.HAZE -> IOSWeatherCondition.Haze
    WeatherCondition.STORMY -> IOSWeatherCondition.Stormy
    WeatherCondition.UNKNOWN,
    null -> IOSWeatherCondition.Unknown
}
