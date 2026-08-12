package com.skybridge.compass.core.utils

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.util.Locale
import java.text.SimpleDateFormat
import java.util.*
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * Context 扩展函数
 */
fun Context.isNetworkAvailable(): Boolean {
    val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    val network = connectivityManager.activeNetwork ?: return false
    val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
    return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
}

fun Context.isWifiConnected(): Boolean {
    val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    val network = connectivityManager.activeNetwork ?: return false
    val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
    return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
}

/**
 * String 扩展函数
 */
fun String.isValidIpAddress(): Boolean {
    return try {
        InetAddress.getByName(this)
        true
    } catch (e: Exception) {
        false
    }
}

fun String.toMacAddressFormat(): String {
    return this.replace(":", "").replace("-", "").chunked(2).joinToString(":")
}

/**
 * Long 扩展函数
 */
fun Long.toFormattedTime(): String {
    val date = Date(this)
    val formatter = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
    return formatter.format(date)
}

fun Long.toRelativeTime(): String {
    val now = System.currentTimeMillis()
    val diff = now - this
    
    return when {
        diff < 60_000 -> "刚刚"
        diff < 3600_000 -> "${diff / 60_000}分钟前"
        diff < 86400_000 -> "${diff / 3600_000}小时前"
        diff < 2592000_000 -> "${diff / 86400_000}天前"
        else -> toFormattedTime()
    }
}

fun Long.formatBytes(): String {
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    var size = this.toDouble()
    var unitIndex = 0
    
    while (size >= 1024 && unitIndex < units.size - 1) {
        size /= 1024
        unitIndex++
    }
    
    return String.format(Locale.ROOT, "%.2f %s", size, units[unitIndex])
}

/**
 * Flow 扩展函数
 */
fun <T> Flow<T>.safeCollect(): Flow<Result<T>> {
    return this.map { Result.success(it) }
        .catch { emit(Result.failure(it)) }
}

/**
 * Result 扩展函数
 */
inline fun <T> Result<T>.onSuccessNotNull(action: (value: T) -> Unit): Result<T> {
    if (isSuccess) {
        val value = getOrNull()
        if (value != null) {
            action(value)
        }
    }
    return this
}

inline fun <T> Result<T>.onFailureWithMessage(action: (message: String) -> Unit): Result<T> {
    if (isFailure) {
        val exception = exceptionOrNull()
        action(exception?.message ?: "Unknown error")
    }
    return this
}

/**
 * 网络工具扩展函数
 */
fun getLocalIpAddress(): String? {
    try {
        val interfaces = NetworkInterface.getNetworkInterfaces()
        while (interfaces.hasMoreElements()) {
            val networkInterface = interfaces.nextElement()
            if (!networkInterface.isLoopback && networkInterface.isUp) {
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (!address.isLoopbackAddress && address.isSiteLocalAddress) {
                        return address.hostAddress
                    }
                }
            }
        }
    } catch (e: Exception) {
        e.printStackTrace()
    }
    return null
}

fun getMacAddress(): String? {
    try {
        val interfaces = NetworkInterface.getNetworkInterfaces()
        while (interfaces.hasMoreElements()) {
            val networkInterface = interfaces.nextElement()
            if (networkInterface.name.equals("wlan0", ignoreCase = true)) {
                val mac = networkInterface.hardwareAddress
                if (mac != null) {
                    return mac.joinToString(":") { "%02x".format(it) }
                }
            }
        }
    } catch (e: Exception) {
        e.printStackTrace()
    }
    return null
}

/**
 * 集合扩展函数
 */
fun <T> List<T>.chunkedBySize(maxSize: Int): List<List<T>> {
    return if (size <= maxSize) {
        listOf(this)
    } else {
        chunked(maxSize)
    }
}

fun <T> List<T>.safeGet(index: Int): T? {
    return if (index in 0 until size) get(index) else null
}

/**
 * 异常扩展函数
 */
fun Throwable.toErrorMessage(): String {
    return when (this) {
        is java.net.ConnectException -> "连接失败"
        is java.net.SocketTimeoutException -> "连接超时"
        is java.net.UnknownHostException -> "主机不可达"
        is java.io.IOException -> "网络错误"
        is SecurityException -> "权限不足"
        else -> message ?: "未知错误"
    }
}
