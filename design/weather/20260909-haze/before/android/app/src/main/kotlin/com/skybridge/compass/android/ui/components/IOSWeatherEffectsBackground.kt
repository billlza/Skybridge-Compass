package com.skybridge.compass.android.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewModelScope
import com.skybridge.compass.android.weather.WeatherCondition
import com.skybridge.compass.android.weather.WeatherRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import javax.inject.Inject
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

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
 * Quantum-glass dashboard chrome (blobs + stars) plus a cinematic weather overlay.
 *
 * The glass layers stay on Canvas so Screen/Overlay blend modes match iOS. Weather used to be
 * hundreds of almost-invisible `drawLine`/`drawCircle` calls; it is now one AGSL pass modeled on
 * the Mac cinematic stack (depth-layered rain/snow, drifting clouds, volumetric fog/haze, storm
 * lightning) at a roughly constant GPU cost.
 */
@Composable
fun IOSDashboardAnimatedBackground(
    condition: IOSWeatherCondition,
    isActive: Boolean,
    modifier: Modifier = Modifier,
    windSpeedKmh: Double = 0.0,
    humidityPercent: Int? = null,
    visibilityKm: Double? = null,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val view = LocalView.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val refreshRate = view.display?.refreshRate ?: 60f
    var hints by remember(context, refreshRate) {
        mutableStateOf(CinematicWeatherPolicy.readHints(context, refreshRate))
    }
    LaunchedEffect(context, refreshRate) {
        while (true) {
            delay(2_000)
            hints = CinematicWeatherPolicy.readHints(context, refreshRate)
        }
    }
    val shouldAnimate = CinematicWeatherPolicy.shouldAnimate(hints)
    val minimumIntervalNs = (
        CinematicWeatherPolicy.minimumIntervalSeconds(condition, hints) * 1_000_000_000.0
        ).toLong().coerceAtLeast(1L)
    val weatherEffect = remember(resources) { CinematicWeatherRuntimeEffect(resources) }
    val overlayIntensity = CinematicWeatherPolicy.overlayIntensity(
        condition = condition,
        windSpeedKmh = windSpeedKmh,
        humidityPercent = humidityPercent,
        visibilityKm = visibilityKm,
    )
    val overlayWind = CinematicWeatherPolicy.overlayWind(windSpeedKmh)
    val overlayQuality = CinematicWeatherPolicy.quality(hints)
    val allowFlash = CinematicWeatherPolicy.allowsStormFlash(hints)

    var timelineSeconds by remember { mutableDoubleStateOf(12.0) }

    LaunchedEffect(minimumIntervalNs, shouldAnimate) {
        if (!shouldAnimate) return@LaunchedEffect
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            val delayMs = (minimumIntervalNs / 1_000_000L).coerceAtLeast(1L)
            var previousFrameNs: Long? = null
            while (true) {
                withFrameNanos { frameNs ->
                    previousFrameNs?.let { previous ->
                        timelineSeconds += (frameNs - previous) / 1_000_000_000.0
                    }
                    previousFrameNs = frameNs
                }
                // Do not subscribe to every display VSYNC only to discard most frames. Waiting
                // between frame requests makes the coroutine itself follow the selected policy.
                delay(delayMs)
            }
        }
    }

    if (isActive && condition == IOSWeatherCondition.Cloudy && weatherEffect.isReady) {
        // Volume lighting is evaluated in a bounded offscreen layer. Upscaling that layer keeps
        // a dense phone display from multiplying the ray-march cost; UI stays at native resolution.
        BoxWithConstraints(modifier = modifier.fillMaxSize()) {
            if (constraints.maxWidth <= 1 || constraints.maxHeight <= 1) return@BoxWithConstraints
            val renderScale = CinematicWeatherPolicy.cloudRenderScale(
                constraints.maxWidth, constraints.maxHeight, overlayQuality,
            )
            Canvas(
                modifier = Modifier
                    .requiredSize(maxWidth * renderScale, maxHeight * renderScale)
                    .graphicsLayer {
                        compositingStrategy = CompositingStrategy.Offscreen
                        transformOrigin = TransformOrigin(0f, 0f)
                        scaleX = constraints.maxWidth / size.width
                        scaleY = constraints.maxHeight / size.height
                    },
            ) {
                weatherEffect.drawOn(
                    scope = this,
                    timeSeconds = timelineSeconds,
                    condition = condition,
                    quality = overlayQuality,
                    intensity = overlayIntensity,
                    wind = overlayWind,
                    allowFlash = allowFlash,
                )
            }
        }
        return
    }

    val blobs = remember {
        listOf(
            FluidBlob(Color(0xFF1A4DBF), 123.4, 567.8, 0.70f, 0.15),
            FluidBlob(Color(0xFF591AA6), 234.5, 678.9, 0.60f, 0.12),
            FluidBlob(Color(0xFF1A738C), 345.6, 789.0, 0.55f, 0.18),
            FluidBlob(Color(0xFF8C2673), 456.7, 890.1, 0.45f, 0.14),
            FluidBlob(Color(0xFF263399), 567.8, 123.4, 0.50f, 0.10)
        )
    }

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

    Canvas(modifier = modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val minDim = min(w, h)
        val blurExtentPx = 80.dp.toPx()

        drawRect(
            brush = Brush.linearGradient(
                colors = listOf(
                    Color(0xFF0A0F2E),
                    Color(0xFF0F0A29),
                    Color(0xFF08081A)
                ),
                start = Offset.Zero,
                end = Offset(w, h)
            )
        )

        drawQuantumFluidBlobs(blobs, timelineSeconds, blurExtentPx, minDim)
        drawQuantumStars(stars, timelineSeconds)

        drawRect(
            color = Color.White,
            alpha = 0.06f,
            blendMode = BlendMode.Overlay
        )

        if (isActive && condition != IOSWeatherCondition.Unknown) {
            drawRect(
                brush = Brush.linearGradient(
                    colors = tintColorsFor(condition),
                    start = Offset.Zero,
                    end = Offset(w, h)
                ),
                alpha = 0.28f
            )
            if (weatherEffect.isReady) {
                weatherEffect.drawOn(
                    scope = this,
                    timeSeconds = timelineSeconds,
                    condition = condition,
                    quality = overlayQuality,
                    intensity = overlayIntensity,
                    wind = overlayWind,
                    allowFlash = allowFlash,
                )
            } else {
                drawCinematicWeatherFallback(
                    condition = condition,
                    timeSeconds = timelineSeconds,
                    intensity = overlayIntensity,
                    wind = overlayWind,
                    allowFlash = allowFlash,
                )
            }
        }
    }
}

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

private fun tintColorsFor(c: IOSWeatherCondition): List<Color> = when (c) {
    IOSWeatherCondition.Clear -> listOf(Color(0x59FFAA33), Color(0x2EFFE066))
    IOSWeatherCondition.Cloudy -> listOf(Color(0x6690A4B8), Color(0x33607080))
    IOSWeatherCondition.Rainy -> listOf(Color(0x423B82F6), Color(0x1F22D3EE))
    IOSWeatherCondition.Snowy -> listOf(Color(0x2ECDEAFB), Color(0x1AF5F8FF))
    IOSWeatherCondition.Foggy -> listOf(Color(0x299AA0AA), Color(0x14EEF2F7))
    IOSWeatherCondition.Haze -> listOf(Color(0x24EFA041), Color(0x24A0A7B5))
    IOSWeatherCondition.Stormy -> listOf(Color(0x384B2DAA), Color(0x2E3366CC))
    IOSWeatherCondition.Unknown -> listOf(Color(0x1A9AA0AA), Color.Transparent)
}

private class IosSeedRNG(seed: Int) {
    private var state: ULong = seed.toULong()
    fun next(): Double {
        state = state * 6364136223846793005uL + 1uL
        return state.toDouble() / ULong.MAX_VALUE.toDouble()
    }
    fun nextIn(lo: Double, hi: Double): Double = lo + next() * (hi - lo)
}

private data class FluidBlob(
    val color: Color,
    val xSeed: Double,
    val ySeed: Double,
    val sizeScale: Float,
    val speed: Double
)

private data class StarParticle(
    val x: Double,
    val y: Double,
    val radius: Float,
    val twinkleSpeed: Double,
    val phase: Double,
    val brightnessScale: Double,
    val color: Color
)

data class IOSBackgroundEffectsUiState(
    val condition: IOSWeatherCondition = IOSWeatherCondition.Unknown,
    val isActive: Boolean = true,
    val windSpeedKmh: Double = 0.0,
    val humidityPercent: Int? = null,
    val visibilityKm: Double? = null,
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
                val snapshot = weatherState.weather
                uiState = uiState.copy(
                    condition = snapshot?.condition.toBackgroundCondition(),
                    windSpeedKmh = snapshot?.windSpeedKmh ?: 0.0,
                    humidityPercent = snapshot?.humidityPercent,
                    visibilityKm = snapshot?.visibilityKm,
                )
            }
            .launchIn(viewModelScope)
        weatherRepository.refreshWeather()
    }
}

internal fun WeatherCondition?.toBackgroundCondition(): IOSWeatherCondition = when (this) {
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
