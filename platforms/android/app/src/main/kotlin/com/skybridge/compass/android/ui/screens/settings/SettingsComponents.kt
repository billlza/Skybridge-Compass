package com.skybridge.compass.android.ui.screens.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.LiquidGlassSurface
import com.skybridge.compass.android.ui.theme.IOSParityTokens

/**
 * Reusable building blocks extracted verbatim from the original ~1187-line SettingsScreen.kt so the
 * per-section composables can share them. Visibility/behavior are unchanged from the original
 * declarations (the inline editor + apply button were `private` to the file; the card composables and
 * the [Setting] model were file-public and are referenced by multiple section files).
 */

data class Setting(
    val title: String,
    val description: String,
    val icon: ImageVector,
    val value: String? = null,
    val route: String? = null
)

/** iOS-like inline editor: small pill field. Was `private fun CompactInlineNumberField`. */
@Composable
internal fun CompactInlineNumberField(
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit
) {
    TextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        placeholder = { Text(placeholder, style = MaterialTheme.typography.labelSmall) },
        textStyle = MaterialTheme.typography.labelLarge,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.10f),
            unfocusedContainerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.08f),
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            cursorColor = IOSParityTokens.ColorTokens.CyanAccent
        ),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
        modifier = Modifier.width(84.dp)
    )
}

/** Was `private fun InlineApplyButton`. */
@Composable
internal fun InlineApplyButton(
    enabled: Boolean,
    onClick: () -> Unit
) {
    LiquidGlassSurface(
        shape = androidx.compose.foundation.shape.RoundedCornerShape(999.dp),
        blurRadius = 0.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = if (enabled) 0.14f else 0.08f),
        tintAlpha = if (enabled) 0.14f else 0.08f,
        borderAlpha = if (enabled) 0.14f else 0.08f,
        highlightAlpha = if (enabled) 0.06f else 0.0f,
        edgeGlowAlpha = if (enabled) 0.05f else 0.0f,
        shadowElevation = if (enabled) 10.dp else 0.dp,
        contentPadding = PaddingValues(0.dp),
        onClick = if (enabled) onClick else null,
        modifier = Modifier.size(34.dp)
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = if (enabled) {
                    resolveLocalizedText("保存", "Save", "保存")
                } else {
                    resolveLocalizedText("已是最新", "Already up to date", "最新の状態です")
                },
                tint = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                modifier = Modifier.size(18.dp)
            )
        }
    }
}

/**
 * Was `private fun InlineSavedIndicator`.
 *
 * Also carries the R7.8 validation-rejection message for the three network number fields: the same
 * single leaf `Text` renders either the green "Saved" confirmation or, when [errorMessage] is
 * non-null, the rejection message (which always names the allowed minimum and maximum). No node is
 * added — the error reuses this existing leaf, so the grouped-container count and nesting depth are
 * unchanged.
 */
@Composable
internal fun InlineSavedIndicator(savedAtMs: Long, errorMessage: String? = null) {
    AnimatedVisibility(
        visible = errorMessage != null || savedAtMs > 0L,
        enter = fadeIn(),
        exit = fadeOut()
    ) {
        Text(
            text = errorMessage ?: resolveLocalizedText("已保存", "Saved", "保存済み"),
            style = MaterialTheme.typography.labelSmall,
            color = if (errorMessage != null) {
                MaterialTheme.colorScheme.error
            } else {
                Color(0xFF34C759) // iOS-like system green
            }
        )
    }
}

@Composable
fun SettingSwitchCard(
    title: String,
    description: String,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        opticalDepth = 18.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(
            alpha = IOSParityTokens.GlassTokens.SectionTintAlpha
        ),
        tintAlpha = IOSParityTokens.GlassTokens.SectionTintAlpha,
        borderAlpha = IOSParityTokens.GlassTokens.SectionBorderAlpha,
        highlightAlpha = IOSParityTokens.GlassTokens.SectionHighlightAlpha,
        edgeGlowAlpha = IOSParityTokens.GlassTokens.SectionEdgeGlowAlpha,
        shadowElevation = 0.dp,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // iOS-like icon tile — cyan accent from the shared parity tokens (5a) so Settings
            // reads from the same accent source as the dashboard / devices / files surfaces.
            LiquidGlassSurface(
                shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
                blurRadius = 0.dp,
                tintColor = IOSParityTokens.ColorTokens.CyanAccent.copy(alpha = 0.16f),
                tintAlpha = 0.16f,
                borderAlpha = 0.12f,
                highlightAlpha = 0.06f,
                edgeGlowAlpha = 0.04f,
                shadowElevation = 0.dp,
                contentPadding = PaddingValues(10.dp)
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = IOSParityTokens.ColorTokens.CyanAccent,
                    modifier = Modifier.size(18.dp)
                )
            }

            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold
                )
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Switch(checked = checked, onCheckedChange = onCheckedChange)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingCard(
    setting: Setting,
    onClick: () -> Unit
) {
    LiquidGlassSurface(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
        blurRadius = 24.dp,
        tintColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
        tintAlpha = 0.28f,
        borderWidth = 1.dp,
        borderAlpha = 0.35f,
        highlightAlpha = 0.22f,
        edgeGlowAlpha = 0.16f
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = setting.icon,
                contentDescription = null,
                tint = IOSParityTokens.ColorTokens.CyanAccent,
                modifier = Modifier.size(24.dp)
            )

            Spacer(modifier = Modifier.width(16.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = setting.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    text = setting.description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (setting.value != null) {
                Text(
                    text = setting.value,
                    style = MaterialTheme.typography.bodySmall,
                    color = IOSParityTokens.ColorTokens.CyanAccent
                )
                Spacer(modifier = Modifier.width(8.dp))
            }

            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
