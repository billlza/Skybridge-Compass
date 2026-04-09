package com.skybridge.compass.mirroring.di

import android.content.Context
import android.media.projection.MediaProjectionManager
import com.skybridge.compass.mirroring.data.repository.ScreenMirroringRepositoryImpl
import com.skybridge.compass.mirroring.data.services.*
import com.skybridge.compass.mirroring.domain.repositories.ScreenMirroringRepository
import com.skybridge.compass.mirroring.domain.usecases.*
import com.skybridge.compass.mirroring.presentation.viewmodel.ScreenMirroringViewModel
import kotlinx.coroutines.runBlocking

/**
 * 屏幕镜像模块的手动依赖注入容器
 * 替代Hilt进行依赖管理
 */
object ScreenMirroringDI {
    
    @Volatile
    private var INSTANCE: ScreenMirroringContainer? = null
    
    fun getInstance(context: Context): ScreenMirroringContainer {
        return INSTANCE ?: synchronized(this) {
            INSTANCE ?: ScreenMirroringContainer(context.applicationContext).also { INSTANCE = it }
        }
    }
    
    fun clearInstance() {
        INSTANCE = null
    }
}

/**
 * 依赖注入容器
 */
class ScreenMirroringContainer(private val context: Context) {
    
    // 系统服务
    private val mediaProjectionManager: MediaProjectionManager by lazy {
        context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    }
    
    // 基础服务层
    private val videoEncoderService: VideoEncoderService by lazy {
        VideoEncoderService()
    }
    
    private val audioMirroringService: AudioMirroringService by lazy {
        AudioMirroringService()
    }
    
    private val mirroringNetworkService: MirroringNetworkService by lazy {
        MirroringNetworkService()
    }
    
    // 业务服务层
    private val screenMirroringService: ScreenMirroringService by lazy {
        ScreenMirroringService(
            context = context,
            mediaProjectionManager = mediaProjectionManager,
            videoEncoderService = videoEncoderService,
            audioMirroringService = audioMirroringService,
            mirroringNetworkService = mirroringNetworkService
        )
    }
    
    // 仓库层
    private val screenMirroringRepository: ScreenMirroringRepository by lazy {
        ScreenMirroringRepositoryImpl(
            screenMirroringService = screenMirroringService,
            videoEncoderService = videoEncoderService,
            audioMirroringService = audioMirroringService,
            mirroringNetworkService = mirroringNetworkService
        )
    }
    
    // 用例层
    private val startMirroringUseCase: StartMirroringUseCase by lazy {
        StartMirroringUseCase(screenMirroringRepository)
    }
    
    private val stopMirroringUseCase: StopMirroringUseCase by lazy {
        StopMirroringUseCase(screenMirroringRepository)
    }
    
    private val pauseMirroringUseCase: PauseMirroringUseCase by lazy {
        PauseMirroringUseCase(screenMirroringRepository)
    }
    
    private val resumeMirroringUseCase: ResumeMirroringUseCase by lazy {
        ResumeMirroringUseCase(screenMirroringRepository)
    }
    
    private val updateMirroringQualityUseCase: UpdateMirroringQualityUseCase by lazy {
        UpdateMirroringQualityUseCase(screenMirroringRepository)
    }
    
    private val toggleAudioUseCase: ToggleAudioUseCase by lazy {
        ToggleAudioUseCase(screenMirroringRepository)
    }
    
    private val reconnectSessionUseCase: ReconnectSessionUseCase by lazy {
        ReconnectSessionUseCase(screenMirroringRepository)
    }
    
    private val getSessionStatsUseCase: GetSessionStatsUseCase by lazy {
        GetSessionStatsUseCase(screenMirroringRepository)
    }
    
    private val optimizeNetworkSettingsUseCase: OptimizeNetworkSettingsUseCase by lazy {
        OptimizeNetworkSettingsUseCase(screenMirroringRepository)
    }
    
    // 提供依赖的公共方法
    fun provideScreenMirroringRepository(): ScreenMirroringRepository = screenMirroringRepository
    
    fun provideScreenMirroringService(): ScreenMirroringService = screenMirroringService
    
    fun provideVideoEncoderService(): VideoEncoderService = videoEncoderService
    
    fun provideAudioMirroringService(): AudioMirroringService = audioMirroringService
    
    fun provideMirroringNetworkService(): MirroringNetworkService = mirroringNetworkService
    
    fun provideStartMirroringUseCase(): StartMirroringUseCase = startMirroringUseCase
    
    fun provideScreenMirroringViewModel(): ScreenMirroringViewModel {
        return ScreenMirroringViewModel(
            screenMirroringRepository = screenMirroringRepository,
            startMirroringUseCase = startMirroringUseCase,
            stopMirroringUseCase = stopMirroringUseCase,
            pauseMirroringUseCase = pauseMirroringUseCase,
            resumeMirroringUseCase = resumeMirroringUseCase,
            updateMirroringQualityUseCase = updateMirroringQualityUseCase,
            toggleAudioUseCase = toggleAudioUseCase,
            reconnectSessionUseCase = reconnectSessionUseCase,
            getSessionStatsUseCase = getSessionStatsUseCase,
            optimizeNetworkSettingsUseCase = optimizeNetworkSettingsUseCase
        )
    }
    
    /**
     * 清理资源
     */
    fun cleanup() {
        try {
            runBlocking { screenMirroringRepository.cleanupFinishedSessions() }
            screenMirroringService.cleanup()
            videoEncoderService.cleanup()
            audioMirroringService.cleanup()
            mirroringNetworkService.cleanup()
        } catch (e: Exception) {
            // 忽略清理时的异常
        }
    }
}