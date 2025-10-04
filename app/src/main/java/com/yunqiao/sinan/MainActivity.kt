package com.yunqiao.sinan

import android.Manifest
import android.app.AlertDialog
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.yunqiao.sinan.data.auth.UserAccount
import com.yunqiao.sinan.manager.DeviceDiscoveryManager
import com.yunqiao.sinan.manager.UserAccountManager
import com.yunqiao.sinan.ui.screen.LoginScreen
import com.yunqiao.sinan.ui.screen.MainScreen
import com.yunqiao.sinan.ui.theme.YunQiaoSiNanTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.hardware.display.DisplayManager
import android.media.projection.MediaProjectionManager

class MainActivity : ComponentActivity() {
    
    companion object {
        private const val TAG = "MainActivity"
        private const val PERMISSION_REQUEST_CODE = 1001
        private const val SYSTEM_NOTIFICATION_CHANNEL = "yunqiao_system"
    }
    
    // 简化的状态管理
    private var initializationProgress by mutableStateOf(0.0f)
    private var initializationMessage by mutableStateOf("准备初始化...")
    private var isInitializationComplete by mutableStateOf(false)
    private var initializationError by mutableStateOf<String?>(null)
    private var authenticatedAccount by mutableStateOf<UserAccount?>(null)

    // 管理器初始化状态
    private var isInitialized = false
    private var hasPermissionDenied = false
    private var isPermissionCheckInProgress = false // 防止重复权限检查
    private var isActivityDestroyed = false // Activity销毁状态
    private var currentPermissionDialog: AlertDialog? = null // 当前权限对话框引用
    private lateinit var userAccountManager: UserAccountManager
    private val deviceDiscoveryManager: DeviceDiscoveryManager by lazy {
        DeviceDiscoveryManager(applicationContext)
    }
    
    // 定义所需权限列表 - 修复版本，分离特殊权限
    private val requiredPermissions = mutableListOf<String>().apply {
        // 基础网络权限
        add(Manifest.permission.INTERNET)
        add(Manifest.permission.ACCESS_NETWORK_STATE)
        add(Manifest.permission.WAKE_LOCK)
        
        // WiFi权限 - 文件传输应用必需
        add(Manifest.permission.ACCESS_WIFI_STATE)
        add(Manifest.permission.CHANGE_WIFI_STATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        
        // 蓝牙权限 - Android 12+ 新权限模型
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            add(Manifest.permission.BLUETOOTH)
            add(Manifest.permission.BLUETOOTH_ADMIN)
        }
        
        // 媒体硬件权限
        add(Manifest.permission.CAMERA)
        add(Manifest.permission.RECORD_AUDIO)
        
        // 位置权限
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
        
        // 存储权限 - 注意：MANAGE_EXTERNAL_STORAGE需要特殊处理，不在这个列表中
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            add(Manifest.permission.READ_MEDIA_VIDEO)
            add(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q) {
                add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
        }
        
        // Android 13+ 通知权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    
    // 检查是否需要MANAGE_EXTERNAL_STORAGE权限
    private fun needsManageExternalStoragePermission(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
    }
    
    // 检查MANAGE_EXTERNAL_STORAGE权限是否已获得
    private fun hasManageExternalStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true // Android 11以下不需要此权限
        }
    }
    
    // 权限请求启动器
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        handlePermissionResults(permissions)
    }
    
    // 设置页面启动器
    private val settingsLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        // 从设置页面返回后，仅在onResume中检查权限
        // 避免双重检查导致的无限循环
        Log.d(TAG, "Returned from settings")
    }
    
    // MANAGE_EXTERNAL_STORAGE权限设置启动器
    private val manageExternalStorageSettingsLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        Log.d(TAG, "Returned from manage external storage settings")
        // 检查权限是否已授予
        if (hasManageExternalStoragePermission()) {
            Log.d(TAG, "MANAGE_EXTERNAL_STORAGE permission granted")
            resetPermissionState()
            initializeApplication()
        } else {
            Log.w(TAG, "MANAGE_EXTERNAL_STORAGE permission still denied")
            // 权限仍被拒绝，显示相应对话框
            showManageExternalStoragePermissionDialog()
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        Log.d(TAG, "onCreate started")
        
        try {
            // 基础初始化
            super.onCreate(savedInstanceState)
            enableEdgeToEdge()

            // 设置状态栏透明
            WindowCompat.setDecorFitsSystemWindows(window, false)

            userAccountManager = UserAccountManager(applicationContext)
            lifecycleScope.launch {
                userAccountManager.currentUser.collectLatest { user ->
                    authenticatedAccount = user
                }
            }

            // 立即设置加载UI
            setupLoadingUI()
            
            Log.d(TAG, "Basic setup completed")
            
            // 检查并请求权限
            checkAndRequestPermissions()
            
        } catch (exception: Exception) {
            Log.e(TAG, "onCreate failed", exception)
            handleCriticalError(exception)
        }
    }
    
    /**
     * 检查并请求权限 - 修复版本，正确处理MANAGE_EXTERNAL_STORAGE
     */
    private fun checkAndRequestPermissions() {
        // 防止重复权限检查和Activity销毁状态检查
        if (isPermissionCheckInProgress) {
            Log.d(TAG, "Permission check already in progress, skipping")
            return
        }
        
        if (isInitialized) {
            Log.d(TAG, "Application already initialized, skipping permission check")
            return
        }
        
        if (isActivityDestroyed || isFinishing) {
            Log.d(TAG, "Activity is destroyed or finishing, skipping permission check")
            return
        }
        
        Log.d(TAG, "Checking permissions")
        isPermissionCheckInProgress = true
        
        // 确保关闭之前的对话框
        dismissCurrentPermissionDialog()
        
        try {
            // 1. 首先检查普通权限
            val deniedNormalPermissions = requiredPermissions.filter { permission ->
                ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED
            }
            
            // 2. 检查MANAGE_EXTERNAL_STORAGE特殊权限
            val needsStoragePermission = needsManageExternalStoragePermission() && !hasManageExternalStoragePermission()
            
            when {
                deniedNormalPermissions.isNotEmpty() -> {
                    // 先处理普通权限
                    Log.d(TAG, "Requesting normal permissions: $deniedNormalPermissions")
                    permissionLauncher.launch(deniedNormalPermissions.toTypedArray())
                }
                needsStoragePermission -> {
                    // 普通权限都通过了，但需要MANAGE_EXTERNAL_STORAGE权限
                    Log.d(TAG, "Requesting MANAGE_EXTERNAL_STORAGE permission")
                    showManageExternalStoragePermissionDialog()
                }
                else -> {
                    // 所有权限都已获得
                    Log.d(TAG, "All permissions granted")
                    resetPermissionState()
                    initializeApplication()
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to check permissions", exception)
            // 权限检查失败时重置状态并使用降级模式
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 重置权限状态
     */
    private fun resetPermissionState() {
        isPermissionCheckInProgress = false
        dismissCurrentPermissionDialog()
    }
    
    /**
     * 关闭当前权限对话框
     */
    private fun dismissCurrentPermissionDialog() {
        try {
            currentPermissionDialog?.let { dialog ->
                if (dialog.isShowing && !isActivityDestroyed && !isFinishing) {
                    dialog.dismiss()
                }
                currentPermissionDialog = null
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to dismiss permission dialog", e)
            currentPermissionDialog = null
        }
    }
    
    /**
     * 处理权限请求结果 - 修复版本，处理完普通权限后检查特殊权限
     */
    private fun handlePermissionResults(permissions: Map<String, Boolean>) {
        Log.d(TAG, "Permission results: $permissions")
        
        try {
            // 检查Activity状态
            if (isActivityDestroyed || isFinishing) {
                Log.w(TAG, "Activity is destroyed or finishing, ignoring permission results")
                resetPermissionState()
                return
            }
            
            val deniedPermissions = permissions.filter { !it.value }.keys
            val permanentlyDenied = deniedPermissions.filter { permission ->
                !ActivityCompat.shouldShowRequestPermissionRationale(this, permission)
            }
            
            when {
                deniedPermissions.isEmpty() -> {
                    Log.d(TAG, "All normal permissions granted")
                    hasPermissionDenied = false
                    
                    // 普通权限都通过了，检查是否需要MANAGE_EXTERNAL_STORAGE权限
                    val needsStoragePermission = needsManageExternalStoragePermission() && !hasManageExternalStoragePermission()
                    
                    if (needsStoragePermission) {
                        Log.d(TAG, "Normal permissions granted, now requesting MANAGE_EXTERNAL_STORAGE")
                        // 不重置权限状态，继续请求特殊权限
                        showManageExternalStoragePermissionDialog()
                    } else {
                        Log.d(TAG, "All permissions granted, initializing application")
                        resetPermissionState()
                        initializeApplication()
                    }
                }
                
                permanentlyDenied.isNotEmpty() -> {
                    Log.w(TAG, "Permanently denied permissions: $permanentlyDenied")
                    hasPermissionDenied = true
                    showPermissionPermanentlyDeniedDialog(permanentlyDenied.toList())
                }
                
                else -> {
                    Log.w(TAG, "Some permissions denied: $deniedPermissions")
                    hasPermissionDenied = true
                    showPermissionRationaleDialog(deniedPermissions.toList())
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to handle permission results", exception)
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 显示权限理由对话框
     */
    private fun showPermissionRationaleDialog(deniedPermissions: List<String>) {
        try {
            // 检查Activity状态
            if (isActivityDestroyed || isFinishing) {
                Log.w(TAG, "Activity is destroyed or finishing, cannot show dialog")
                resetPermissionState()
                return
            }
            
            // 关闭之前的对话框
            dismissCurrentPermissionDialog()
            
            val message = buildString {
                append("应用需要以下权限才能正常运行：\n\n")
                deniedPermissions.forEach { permission ->
                    append("• ${getPermissionDescription(permission)}\n")
                }
                append("\n是否重新请求权限？")
            }
            
            currentPermissionDialog = AlertDialog.Builder(this)
                .setTitle("权限请求")
                .setMessage(message)
                .setPositiveButton("重新请求") { dialog, _ ->
                    dialog.dismiss()
                    currentPermissionDialog = null
                    // 重新请求权限前重置状态
                    resetPermissionState()
                    isPermissionCheckInProgress = true
                    permissionLauncher.launch(deniedPermissions.toTypedArray())
                }
                .setNegativeButton("使用基础功能") { dialog, _ ->
                    dialog.dismiss()
                    currentPermissionDialog = null
                    resetPermissionState()
                    initializeApplicationWithDegradedMode()
                }
                .setCancelable(false)
                .setOnDismissListener {
                    currentPermissionDialog = null
                }
                .create()
                
            // 安全显示对话框
            if (!isActivityDestroyed && !isFinishing) {
                currentPermissionDialog?.show()
            } else {
                currentPermissionDialog = null
                resetPermissionState()
            }
            
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to show permission rationale dialog", exception)
            currentPermissionDialog = null
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 显示权限永久拒绝对话框
     */
    private fun showPermissionPermanentlyDeniedDialog(deniedPermissions: List<String>) {
        try {
            // 检查Activity状态
            if (isActivityDestroyed || isFinishing) {
                Log.w(TAG, "Activity is destroyed or finishing, cannot show dialog")
                resetPermissionState()
                return
            }
            
            // 关闭之前的对话框
            dismissCurrentPermissionDialog()
            
            val message = buildString {
                append("以下权限被永久拒绝：\n\n")
                deniedPermissions.forEach { permission ->
                    append("• ${getPermissionDescription(permission)}\n")
                }
                append("\n请前往设置页面手动开启权限。")
            }
            
            currentPermissionDialog = AlertDialog.Builder(this)
                .setTitle("权限设置")
                .setMessage(message)
                .setPositiveButton("前往设置") { dialog, _ ->
                    dialog.dismiss()
                    currentPermissionDialog = null
                    resetPermissionState()
                    openAppSettings()
                }
                .setNegativeButton("使用基础功能") { dialog, _ ->
                    dialog.dismiss()
                    currentPermissionDialog = null
                    resetPermissionState()
                    initializeApplicationWithDegradedMode()
                }
                .setCancelable(false)
                .setOnDismissListener {
                    currentPermissionDialog = null
                }
                .create()
                
            // 安全显示对话框
            if (!isActivityDestroyed && !isFinishing) {
                currentPermissionDialog?.show()
            } else {
                currentPermissionDialog = null
                resetPermissionState()
            }
            
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to show permission permanently denied dialog", exception)
            currentPermissionDialog = null
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 显示MANAGE_EXTERNAL_STORAGE权限对话框 - 新增方法
     */
    private fun showManageExternalStoragePermissionDialog() {
        try {
            // 检查Activity状态
            if (isActivityDestroyed || isFinishing) {
                Log.w(TAG, "Activity is destroyed or finishing, cannot show dialog")
                resetPermissionState()
                return
            }
            
            // 关闭之前的对话框
            dismissCurrentPermissionDialog()
            
            val message = "应用需要以下权限才能正常运行：\n\n" +
                    "• 完整文件访问 (Android 11+)\n\n" +
                    "是否重新请求权限？"
            
            currentPermissionDialog = AlertDialog.Builder(this)
                .setTitle("权限请求")
                .setMessage(message)
                .setPositiveButton("重新请求") { dialog, _ ->
                    dialog.dismiss()
                    currentPermissionDialog = null
                    // 按照Claude建议：先检查权限，如果未授予，再发起Intent跳转
                    if (hasManageExternalStoragePermission()) {
                        Log.d(TAG, "MANAGE_EXTERNAL_STORAGE permission already granted")
                        resetPermissionState()
                        initializeApplication()
                    } else {
                        Log.d(TAG, "MANAGE_EXTERNAL_STORAGE permission not granted, opening settings")
                        openManageExternalStorageSettings()
                    }
                }
                .setNegativeButton("使用基础功能") { dialog, _ ->
                    dialog.dismiss()
                    currentPermissionDialog = null
                    resetPermissionState()
                    initializeApplicationWithDegradedMode()
                }
                .setCancelable(false)
                .setOnDismissListener {
                    currentPermissionDialog = null
                }
                .create()
                
            // 安全显示对话框
            if (!isActivityDestroyed && !isFinishing) {
                currentPermissionDialog?.show()
            } else {
                currentPermissionDialog = null
                resetPermissionState()
            }
            
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to show manage external storage permission dialog", exception)
            currentPermissionDialog = null
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 获取权限描述
     */
    private fun getPermissionDescription(permission: String): String {
        return when (permission) {
            Manifest.permission.ACCESS_FINE_LOCATION -> "精确位置（天气功能需要）"
            Manifest.permission.ACCESS_COARSE_LOCATION -> "大致位置（天气功能需要）"
            Manifest.permission.ACCESS_WIFI_STATE -> "WiFi状态访问（设备发现需要）"
            Manifest.permission.CHANGE_WIFI_STATE -> "WiFi设置管理（热点功能需要）"
            Manifest.permission.NEARBY_WIFI_DEVICES -> "附近WiFi设备扫描（Android 13+）"
            Manifest.permission.BLUETOOTH_SCAN -> "蓝牙设备扫描（Android 12+）"
            Manifest.permission.BLUETOOTH_ADVERTISE -> "蓝牙广播（Android 12+）"
            Manifest.permission.BLUETOOTH_CONNECT -> "蓝牙连接（Android 12+）"
            Manifest.permission.BLUETOOTH -> "蓝牙访问（传统权限）"
            Manifest.permission.BLUETOOTH_ADMIN -> "蓝牙管理（传统权限）"
            Manifest.permission.CAMERA -> "摄像头访问（文件拍摄需要）"
            Manifest.permission.RECORD_AUDIO -> "麦克风访问（语音功能需要）"
            Manifest.permission.MANAGE_EXTERNAL_STORAGE -> "完整文件访问（Android 11+）"
            Manifest.permission.POST_NOTIFICATIONS -> "通知权限（Android 13+）"
            Manifest.permission.READ_MEDIA_IMAGES -> "图片访问（Android 13+）"
            Manifest.permission.READ_MEDIA_VIDEO -> "视频访问（Android 13+）"
            Manifest.permission.READ_MEDIA_AUDIO -> "音频访问（Android 13+）"
            Manifest.permission.READ_EXTERNAL_STORAGE -> "存储读取（传统权限）"
            Manifest.permission.WRITE_EXTERNAL_STORAGE -> "存储写入（传统权限）"
            else -> permission.substringAfterLast(".")
        }
    }
    
    /**
     * 打开应用设置页面
     */
    private fun openAppSettings() {
        try {
            if (isActivityDestroyed || isFinishing) {
                Log.w(TAG, "Activity is destroyed or finishing, cannot open settings")
                resetPermissionState()
                return
            }
            
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
            settingsLauncher.launch(intent)
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to open app settings", exception)
            Toast.makeText(this, "无法打开设置页面", Toast.LENGTH_SHORT).show()
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 打开MANAGE_EXTERNAL_STORAGE权限设置页面 - 新增方法
     */
    private fun openManageExternalStorageSettings() {
        try {
            if (isActivityDestroyed || isFinishing) {
                Log.w(TAG, "Activity is destroyed or finishing, cannot open settings")
                resetPermissionState()
                return
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    // 首先尝试直接打开所有文件访问权限设置页面
                    val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    manageExternalStorageSettingsLauncher.launch(intent)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to open specific storage permission page, trying app settings", e)
                    // 如果失败，则打开应用详情设置页面
                    val fallbackIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.fromParts("package", packageName, null)
                    }
                    manageExternalStorageSettingsLauncher.launch(fallbackIntent)
                }
            } else {
                // Android 11以下不需要此权限，直接初始化
                Log.d(TAG, "Android version < 11, MANAGE_EXTERNAL_STORAGE not needed")
                resetPermissionState()
                initializeApplication()
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to open manage external storage settings", exception)
            Toast.makeText(this, "无法打开文件访问权限设置页面，请手动在设置中开启文件访问权限", Toast.LENGTH_LONG).show()
            resetPermissionState()
            initializeApplicationWithDegradedMode()
        }
    }
    
    /**
     * 初始化应用 - 真实组件初始化版本
     */
    private fun initializeApplication() {
        if (isInitialized) {
            Log.d(TAG, "Application already initialized")
            return
        }
        
        Log.d(TAG, "Starting application initialization")
        
        try {
            lifecycleScope.launch(Dispatchers.Main) {
                try {
                    // 1. 网络组件初始化
                    initializationMessage = "正在初始化网络组件..."
                    initializationProgress = 0.1f
                    initializeNetworkManager()
                    
                    // 2. 存储组件初始化
                    initializationMessage = "正在初始化存储组件..."
                    initializationProgress = 0.3f
                    initializeStorageManager()
                    
                    // 3. 设备发现组件初始化
                    initializationMessage = "正在初始化设备发现..."
                    initializationProgress = 0.5f
                    initializeDeviceDiscoveryManager()
                    
                    // 4. 媒体组件初始化
                    initializationMessage = "正在初始化媒体组件..."
                    initializationProgress = 0.7f
                    initializeMediaManager()
                    
                    // 5. 服务组件初始化
                    initializationMessage = "正在启动后台服务..."
                    initializationProgress = 0.9f
                    initializeBackgroundServices()
                    
                    // 6. 完成初始化
                    initializationMessage = "初始化完成"
                    initializationProgress = 1.0f
                    delay(200)
                    
                    // 完成初始化
                    isInitializationComplete = true
                    isInitialized = true
                    resetPermissionState() // 确保重置权限检查状态
                    
                    Log.d(TAG, "Application initialized successfully")
                    
                } catch (exception: Exception) {
                    Log.e(TAG, "Failed to initialize application", exception)
                    initializationError = "初始化失败: ${exception.message}"
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to start application initialization", exception)
            handleCriticalError(exception)
        }
    }
    
    /**
     * 网络管理器初始化
     */
    private suspend fun initializeNetworkManager() {
        withContext(Dispatchers.IO) {
            try {
                Log.d(TAG, "Initializing network manager")
                val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val activeNetwork = connectivityManager.activeNetwork
                    ?: throw IllegalStateException("当前无可用网络")
                val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
                    ?: throw IllegalStateException("无法获取网络能力")
                if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                    throw IllegalStateException("当前网络不具备互联网访问能力")
                }
                connectivityManager.getLinkProperties(activeNetwork)
                    ?: throw IllegalStateException("网络链路信息缺失")
                Log.d(TAG, "Network manager initialized with capabilities: $capabilities")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize network manager", e)
                throw e
            }
        }
    }
    
    /**
     * 存储管理器初始化
     */
    private suspend fun initializeStorageManager() {
        withContext(Dispatchers.IO) {
            try {
                Log.d(TAG, "Initializing storage manager")
                val hasStoragePermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Environment.isExternalStorageManager()
                } else {
                    ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.READ_EXTERNAL_STORAGE
                    ) == PackageManager.PERMISSION_GRANTED
                }
                if (!hasStoragePermission) {
                    throw IllegalStateException("缺少外部存储访问权限")
                }

                val targetDirs = listOfNotNull(
                    getExternalFilesDir(null)?.resolve("transfers"),
                    getExternalFilesDir(null)?.resolve("logs"),
                    filesDir.resolve("cache"),
                    filesDir.resolve("telemetry")
                )
                targetDirs.forEach { dir ->
                    if (!dir.exists() && !dir.mkdirs()) {
                        throw IllegalStateException("无法创建目录: ${dir.absolutePath}")
                    }
                }
                Log.d(TAG, "Storage manager initialized, directories ready")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize storage manager", e)
                throw e
            }
        }
    }
    
    /**
     * 设备发现管理器初始化
     */
    private suspend fun initializeDeviceDiscoveryManager() {
        withContext(Dispatchers.IO) {
            try {
                Log.d(TAG, "Initializing device discovery manager")
                val discoveryManager = deviceDiscoveryManager
                val hasWifiPermission = ContextCompat.checkSelfPermission(
                    this@MainActivity,
                    Manifest.permission.ACCESS_WIFI_STATE
                ) == PackageManager.PERMISSION_GRANTED
                val hasBluetoothPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.BLUETOOTH_SCAN
                    ) == PackageManager.PERMISSION_GRANTED &&
                        ContextCompat.checkSelfPermission(
                            this@MainActivity,
                            Manifest.permission.BLUETOOTH_CONNECT
                        ) == PackageManager.PERMISSION_GRANTED
                } else {
                    ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.BLUETOOTH
                    ) == PackageManager.PERMISSION_GRANTED
                }
                if (!hasWifiPermission && !hasBluetoothPermission) {
                    throw IllegalStateException("缺少附近设备发现所需的无线权限")
                }
                discoveryManager.startDiscovery()
                Log.d(TAG, "Device discovery manager initialized and discovery started")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize device discovery manager", e)
                throw e
            }
        }
    }
    
    /**
     * 媒体管理器初始化
     */
    private suspend fun initializeMediaManager() {
        withContext(Dispatchers.IO) {
            try {
                Log.d(TAG, "Initializing media manager")
                val hasCameraPermission = ContextCompat.checkSelfPermission(
                    this@MainActivity,
                    Manifest.permission.CAMERA
                ) == PackageManager.PERMISSION_GRANTED
                val hasAudioPermission = ContextCompat.checkSelfPermission(
                    this@MainActivity,
                    Manifest.permission.RECORD_AUDIO
                ) == PackageManager.PERMISSION_GRANTED
                if (!hasCameraPermission || !hasAudioPermission) {
                    throw IllegalStateException("缺少媒体采集所需的关键权限")
                }

                val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
                    ?: throw IllegalStateException("无法获取MediaProjection服务")
                val displayManager = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
                    ?: throw IllegalStateException("无法获取DisplayManager")
                val audioManager = getSystemService(Context.AUDIO_SERVICE)
                    ?: throw IllegalStateException("无法获取音频服务")

                Log.d(
                    TAG,
                    "Media manager initialized with projectionManager=$projectionManager displayManager=$displayManager audioManager=$audioManager"
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize media manager", e)
                throw e
            }
        }
    }
    
    /**
     * 后台服务初始化
     */
    private suspend fun initializeBackgroundServices() {
        withContext(Dispatchers.IO) {
            try {
                Log.d(TAG, "Initializing background services")
                val hasNotificationPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.POST_NOTIFICATIONS
                    ) == PackageManager.PERMISSION_GRANTED
                } else {
                    true
                }
                if (!hasNotificationPermission) {
                    throw IllegalStateException("缺少通知权限，无法启动通知中心")
                }

                val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val channel = NotificationChannel(
                        SYSTEM_NOTIFICATION_CHANNEL,
                        "系统通知",
                        NotificationManager.IMPORTANCE_DEFAULT
                    ).apply {
                        description = "云桥司南运行状态与连接提示"
                    }
                    notificationManager.createNotificationChannel(channel)
                }
                Log.d(TAG, "Background services initialized with notification channels")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize background services", e)
                throw e
            }
        }
    }
    
    /**
     * 初始化应用（降级模式）- 真实组件初始化版本
     */
    private fun initializeApplicationWithDegradedMode() {
        if (isInitialized) {
            Log.d(TAG, "Application already initialized")
            return
        }
        
        Log.w(TAG, "Initializing application in degraded mode")
        
        try {
            lifecycleScope.launch(Dispatchers.Main) {
                try {
                    initializationMessage = "正在以基础模式初始化..."
                    initializationProgress = 0.2f
                    
                    // 基础模式下只初始化核心组件
                    initializeNetworkManagerSafe()
                    
                    initializationMessage = "基础网络组件已就绪..."
                    initializationProgress = 0.6f
                    delay(200)
                    
                    initializationMessage = "基础模式初始化完成"
                    initializationProgress = 1.0f
                    delay(200)
                    
                    // 完成初始化
                    isInitializationComplete = true
                    isInitialized = true
                    resetPermissionState() // 确保重置权限检查状态
                    
                    Log.d(TAG, "Application initialized in degraded mode")
                    
                    // 显示降级模式提示
                    if (hasPermissionDenied) {
                        Toast.makeText(this@MainActivity, "部分功能受限，建议开启所有权限", Toast.LENGTH_LONG).show()
                    }
                    
                } catch (exception: Exception) {
                    Log.e(TAG, "Failed to initialize application in degraded mode", exception)
                    handleCriticalError(exception)
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Failed to start degraded application initialization", exception)
            handleCriticalError(exception)
        }
    }
    
    /**
     * 安全模式网络管理器初始化
     */
    private suspend fun initializeNetworkManagerSafe() {
        withContext(Dispatchers.IO) {
            try {
                Log.d(TAG, "Initializing network manager in safe mode")
                val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                connectivityManager.activeNetwork ?: Log.w(TAG, "No active network during safe initialization")
                Log.d(TAG, "Safe network manager initialized")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to initialize safe network manager", e)
            }
        }
    }
    
    /**
     * 设置加载UI
     */
    private fun setupLoadingUI() {
        setContent {
            val systemDarkTheme = isSystemInDarkTheme()
            var isDarkTheme by remember { mutableStateOf(systemDarkTheme) }
            var useDynamicColor by remember { mutableStateOf(true) }
            
            YunQiaoSiNanTheme(
                darkTheme = isDarkTheme,
                dynamicColor = useDynamicColor
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    if (isInitializationComplete) {
                        val account = authenticatedAccount
                        if (account != null) {
                            MainScreen(
                                onThemeChange = { dark, dynamic ->
                                    isDarkTheme = dark
                                    useDynamicColor = dynamic
                                },
                                currentAccount = account
                            )
                        } else {
                            LoginScreen(
                                userAccountManager = userAccountManager,
                                onAuthenticated = { authenticatedAccount = it }
                            )
                        }
                    } else {
                        InitializationScreen(
                            progress = initializationProgress,
                            message = initializationMessage,
                            error = initializationError,
                            onRetry = {
                                initializationError = null
                                initializationProgress = 0f
                                initializationMessage = "重新初始化..."
                                isInitialized = false
                                resetPermissionState() // 重置权限检查状态
                                checkAndRequestPermissions()
                            }
                        )
                    }
                }
            }
        }
    }
    
    /**
     * 初始化进度界面
     */
    @Composable
    private fun InitializationScreen(
        progress: Float,
        message: String,
        error: String?,
        onRetry: () -> Unit
    ) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // 应用Logo/图标
                Card(
                    modifier = Modifier.size(80.dp),
                    elevation = CardDefaults.cardElevation(defaultElevation = 8.dp)
                ) {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "云桥",
                            style = MaterialTheme.typography.headlineSmall
                        )
                    }
                }
                
                Spacer(modifier = Modifier.height(24.dp))
                
                if (error != null) {
                    // 错误状态
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Error,
                            contentDescription = "Error",
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(48.dp)
                        )
                        Text(
                            text = "初始化失败",
                            style = MaterialTheme.typography.headlineSmall,
                            color = MaterialTheme.colorScheme.error
                        )
                        Text(
                            text = error,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        
                        Spacer(modifier = Modifier.height(16.dp))
                        
                        Button(onClick = onRetry) {
                            Text("重试")
                        }
                    }
                } else {
                    // 正常加载状态
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(
                            progress = progress,
                            modifier = Modifier.size(48.dp),
                            strokeWidth = 4.dp
                        )
                        
                        Text(
                            text = "正在初始化应用",
                            style = MaterialTheme.typography.headlineSmall
                        )
                        
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        
                        // 进度百分比
                        Text(
                            text = "${(progress * 100).toInt()}%",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            }
        }
    }
    
    /**
     * 处理关键错误
     */
    private fun handleCriticalError(exception: Exception) {
        Log.e(TAG, "Critical error occurred", exception)
        
        try {
            // 清理状态和资源
            resetPermissionState()
            
            initializationError = "启动失败: ${exception.message}"
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set error message", e)
            // 如果连设置错误信息都失败了，直接使用降级模式
            try {
                resetPermissionState()
                initializeApplicationWithDegradedMode()
            } catch (degradedException: Exception) {
                // 最后的手段：显示Toast并退出
                Log.e(TAG, "Failed to initialize in degraded mode", degradedException)
                try {
                    Toast.makeText(this, "应用启动失败，即将退出", Toast.LENGTH_LONG).show()
                    finish()
                } catch (toastException: Exception) {
                    Log.e(TAG, "Failed to show toast", toastException)
                    finish()
                }
            }
        }
    }
    
    override fun onResume() {
        super.onResume()
        
        try {
            Log.d(TAG, "onResume called")
            
            // 重置Activity销毁状态
            isActivityDestroyed = false
            
            // 只有在应用完全未初始化且没有权限检查正在进行时，才尝试重新初始化
            if (!isInitialized && !isPermissionCheckInProgress && !isFinishing) {
                Log.d(TAG, "Application not initialized, checking permissions")
                checkAndRequestPermissions()
            } else if (isInitialized) {
                Log.d(TAG, "Application already initialized")
            } else if (isPermissionCheckInProgress) {
                Log.d(TAG, "Permission check in progress, waiting")
            } else {
                Log.d(TAG, "Activity is finishing, skipping initialization")
            }
        } catch (exception: Exception) {
            Log.e(TAG, "Error in onResume", exception)
        }
    }
    
    override fun onDestroy() {
        try {
            Log.d(TAG, "onDestroy called")
            isActivityDestroyed = true
            dismissCurrentPermissionDialog()
            super.onDestroy()
        } catch (exception: Exception) {
            Log.e(TAG, "Error in onDestroy", exception)
        }
    }
}