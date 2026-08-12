package com.skybridge.compass.android.ui.screens.settings

import com.skybridge.compass.android.i18n.resolveLocalizedText
import com.skybridge.compass.core.data.NetworkSettingField
import com.skybridge.compass.core.data.NetworkSettingRejection

/**
 * 把数据层的 [NetworkSettingRejection] 渲染为用户可读提示（R7.8）。
 *
 * 不变量：返回文案**必定同时包含**该字段最小值与最大值的十进制文本，因此「提示含最小与最大值」
 * 不依赖具体语言分支。
 *
 * 发现超时按**毫秒**展示声明区间（250–120000）：其最小值 250ms 无法用整数秒表示，若换算成秒
 * 会把下限错报为 0，反而违背 R7.8「提示含最小值」。
 */
fun networkSettingRejectionMessage(rejection: NetworkSettingRejection): String {
    val min = rejection.min.toString()
    val max = rejection.max.toString()
    val unit = if (rejection.settingField == NetworkSettingField.DISCOVERY_TIMEOUT_MS) {
        resolveLocalizedText(" 毫秒", " ms", " ミリ秒")
    } else {
        ""
    }
    return when (rejection) {
        is NetworkSettingRejection.Empty -> resolveLocalizedText(
            zh = "不能为空，请输入 $min–$max$unit",
            en = "Cannot be empty; enter $min-$max$unit",
            ja = "空にできません。$min–$max$unit を入力してください"
        )

        is NetworkSettingRejection.NotNumeric -> resolveLocalizedText(
            zh = "必须为整数，范围 $min–$max$unit",
            en = "Must be an integer between $min and $max$unit",
            ja = "整数で入力してください（$min–$max$unit）"
        )

        is NetworkSettingRejection.OutOfRange -> resolveLocalizedText(
            zh = "超出范围，允许 $min–$max$unit",
            en = "Out of range; allowed $min-$max$unit",
            ja = "範囲外です。許容 $min–$max$unit"
        )

        is NetworkSettingRejection.EndBeforeStart -> resolveLocalizedText(
            zh = "结束需 ≥ 起始 ${rejection.start}，范围 $min–$max",
            en = "End must be >= start ${rejection.start}; range $min-$max",
            ja = "終了は開始 ${rejection.start} 以上、範囲 $min–$max"
        )
    }
}
