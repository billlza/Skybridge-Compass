package com.skybridge.compass.android.ui.screens.settings

import com.skybridge.compass.android.i18n.resolveLocalizedText

/**
 * 把 [SettingSaveFailure] 渲染为用户可读的「保存未生效」提示（R7.12）。
 *
 * 不变量：文案必定表达「未生效 / 未保存」，而不是含糊的「出错了」——R7.12 要求提示**指示保存
 * 未生效**，用户据此知道自己看到的显示值仍是旧的已持久化值，而非刚才那次操作的结果。
 *
 * 与 `networkSettingRejectionMessage`（R7.8 的范围提示）是两条独立的文案通道：
 * 前者说「你输入的值不合法，范围是 A–B」，本文件说「值合法但没能写进去，显示值已回到原值」。
 */
fun settingSaveFailureMessage(failure: SettingSaveFailure): String = resolveLocalizedText(
    zh = "保存未生效，已恢复为原值",
    en = "Not saved; reverted to the previous value",
    ja = "保存されていません。元の値に戻しました"
)
