package com.skybridge.compass.android.i18n

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import com.skybridge.compass.android.data.APP_LANGUAGE_EN
import com.skybridge.compass.android.data.APP_LANGUAGE_JA
import com.skybridge.compass.android.data.APP_LANGUAGE_SYSTEM
import com.skybridge.compass.android.data.APP_LANGUAGE_ZH
import java.util.Locale

object AppLanguageRuntime {
    var overrideLanguage by mutableStateOf<String?>(null)
        private set

    fun applySetting(setting: String?) {
        overrideLanguage = when (setting?.lowercase(Locale.ROOT)) {
            APP_LANGUAGE_ZH -> APP_LANGUAGE_ZH
            APP_LANGUAGE_EN -> APP_LANGUAGE_EN
            APP_LANGUAGE_JA -> APP_LANGUAGE_JA
            else -> null
        }
    }
}

@Composable
fun localizedText(
    zh: String,
    en: String,
    ja: String
): String {
    val configuration = LocalConfiguration.current
    val overrideLanguage = AppLanguageRuntime.overrideLanguage
    val language = remember(configuration, overrideLanguage) {
        overrideLanguage ?: currentLanguage(configuration)
    }
    return remember(language, zh, en, ja) {
        resolveLocalizedText(language, zh, en, ja)
    }
}

fun resolveLocalizedText(
    zh: String,
    en: String,
    ja: String,
    locale: Locale = Locale.getDefault()
): String = resolveLocalizedText(AppLanguageRuntime.overrideLanguage ?: locale.language, zh, en, ja)

fun resolveLanguageLabel(setting: String, zhLabel: String, enLabel: String, jaLabel: String): String =
    when (setting.lowercase(Locale.ROOT)) {
        APP_LANGUAGE_ZH -> zhLabel
        APP_LANGUAGE_EN -> enLabel
        APP_LANGUAGE_JA -> jaLabel
        APP_LANGUAGE_SYSTEM -> resolveLocalizedText("跟随系统", "Follow System", "システムに従う")
        else -> resolveLocalizedText("跟随系统", "Follow System", "システムに従う")
    }

fun resolveLocalizedTextForSetting(
    setting: String?,
    zh: String,
    en: String,
    ja: String,
    locale: Locale = Locale.getDefault()
): String = when (setting?.lowercase(Locale.ROOT)) {
    APP_LANGUAGE_EN -> en
    APP_LANGUAGE_JA -> ja
    APP_LANGUAGE_ZH -> zh
    else -> resolveLocalizedText(zh, en, ja, locale)
}

fun currentAppLocale(locale: Locale = Locale.getDefault()): Locale =
    when (AppLanguageRuntime.overrideLanguage?.lowercase(Locale.ROOT)) {
        APP_LANGUAGE_EN -> Locale.ENGLISH
        APP_LANGUAGE_JA -> Locale.JAPANESE
        APP_LANGUAGE_ZH -> Locale.SIMPLIFIED_CHINESE
        else -> locale
    }

fun resolveLocalizedText(
    language: String,
    zh: String,
    en: String,
    ja: String
): String = when (language.lowercase(Locale.ROOT)) {
    "en" -> en
    "ja" -> ja
    else -> zh
}

private fun currentLanguage(configuration: android.content.res.Configuration): String {
    return configuration.locales[0]?.language ?: Locale.getDefault().language
}
