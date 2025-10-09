package com.yunqiao.sinan.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

class StatusWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        StatusWidgetUpdater.updateWidgets(context)
    }

    override fun onEnabled(context: Context) {
        StatusWidgetUpdater.updateWidgets(context)
    }
}
