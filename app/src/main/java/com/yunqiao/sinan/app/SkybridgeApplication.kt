package com.yunqiao.sinan.app

import android.app.Application
import com.yunqiao.sinan.config.ConfigurationManager

class SkybridgeApplication : Application() {
    private lateinit var exceptionHandler: GlobalExceptionHandler

    override fun onCreate() {
        super.onCreate()
        exceptionHandler = GlobalExceptionHandler(this)
        exceptionHandler.install()
        ConfigurationManager.initialize(this)
    }
}
