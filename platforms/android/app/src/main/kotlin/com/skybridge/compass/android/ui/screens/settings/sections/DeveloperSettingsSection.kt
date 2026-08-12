package com.skybridge.compass.android.ui.screens.settings.sections

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.automirrored.filled.ScreenShare
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import com.skybridge.compass.android.data.DeveloperSettings
import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.android.ui.components.GroupedGlassDivider
import com.skybridge.compass.android.ui.components.GroupedGlassRow
import com.skybridge.compass.android.ui.components.GroupedGlassSection
import com.skybridge.compass.android.ui.screens.settings.SettingSwitchCard

/**
 * "深度开发设置 / Advanced Developer Settings" feature-flag toggles — extracted verbatim from
 * SettingsScreen.kt. These three cards were each their own `item {}` in the original LazyColumn; the
 * screen still renders them as separate items, calling the individual composables below so the list
 * structure is unchanged. Each toggle is wired to the same [DeveloperSettings] field and the same
 * ViewModel intent, which persists the value to `DeveloperSettingsStore` (the real feature gate).
 */

@Composable
fun DeveloperScreenMirroringCard(
    developerSettings: DeveloperSettings,
    onChange: (Boolean) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    SettingSwitchCard(
        title = t("屏幕镜像", "Screen Mirroring", "画面ミラーリング"),
        description = t("启用屏幕镜像模块", "Enable the screen mirroring module", "画面ミラーリング機能を有効にする"),
        icon = Icons.Default.Settings,
        checked = developerSettings.enableScreenMirroring,
        onCheckedChange = onChange
    )
}

@Composable
fun DeveloperRemoteControlCard(
    developerSettings: DeveloperSettings,
    onChange: (Boolean) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    SettingSwitchCard(
        title = t("远程控制", "Remote Control", "リモート操作"),
        description = t("启用远程控制模块", "Enable the remote control module", "リモート操作機能を有効にする"),
        icon = Icons.Default.Settings,
        checked = developerSettings.enableRemoteControl,
        onCheckedChange = onChange
    )
}

@Composable
fun DeveloperFileTransferCard(
    developerSettings: DeveloperSettings,
    onChange: (Boolean) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)
    SettingSwitchCard(
        title = t("文件传输", "File Transfer", "ファイル転送"),
        description = t("启用文件传输模块", "Enable the file transfer module", "ファイル転送機能を有効にする"),
        icon = Icons.Default.Folder,
        checked = developerSettings.enableFileTransfer,
        onCheckedChange = onChange
    )
}

@Composable
fun DeveloperSettingsSectionGrouped(
    developerSettings: DeveloperSettings,
    onScreenMirroringChange: (Boolean) -> Unit,
    onRemoteControlChange: (Boolean) -> Unit,
    onFileTransferChange: (Boolean) -> Unit
) {
    fun t(zh: String, en: String, ja: String): String = resolveLocalizedText(zh, en, ja)

    GroupedGlassSection(title = t("深度开发设置", "Advanced Developer Settings", "開発者向け詳細設定")) {
        GroupedGlassRow(
            title = t("屏幕镜像", "Screen Mirroring", "画面ミラーリング"),
            subtitle = t("启用屏幕镜像模块", "Enable the screen mirroring module", "画面ミラーリング機能を有効にする"),
            icon = Icons.AutoMirrored.Filled.ScreenShare
        ) {
            Switch(
                checked = developerSettings.enableScreenMirroring,
                onCheckedChange = onScreenMirroringChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("远程控制", "Remote Control", "リモート操作"),
            subtitle = t("启用远程控制模块", "Enable the remote control module", "リモート操作機能を有効にする"),
            icon = Icons.Default.Computer
        ) {
            Switch(
                checked = developerSettings.enableRemoteControl,
                onCheckedChange = onRemoteControlChange
            )
        }
        GroupedGlassDivider()
        GroupedGlassRow(
            title = t("文件传输", "File Transfer", "ファイル転送"),
            subtitle = t("启用文件传输模块", "Enable the file transfer module", "ファイル転送機能を有効にする"),
            icon = Icons.Default.Folder
        ) {
            Switch(
                checked = developerSettings.enableFileTransfer,
                onCheckedChange = onFileTransferChange
            )
        }
    }
}
