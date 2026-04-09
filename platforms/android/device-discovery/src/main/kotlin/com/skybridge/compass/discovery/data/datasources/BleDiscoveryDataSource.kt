package com.skybridge.compass.discovery.data.datasources

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import android.Manifest
import androidx.core.app.ActivityCompat
import com.skybridge.compass.discovery.domain.entities.ConnectionInfo
import com.skybridge.compass.discovery.data.telemetry.DiscoveryTelemetry
import com.skybridge.compass.discovery.domain.entities.DeviceCapability
import com.skybridge.compass.discovery.domain.entities.DeviceType
import com.skybridge.compass.discovery.domain.entities.DiscoveredDevice
import com.skybridge.compass.discovery.domain.entities.DiscoveryProtocol
import com.skybridge.compass.discovery.domain.entities.PreferredConnect
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BleDiscoveryDataSource @Inject constructor(
    @ApplicationContext private val context: android.content.Context,
    private val telemetry: DiscoveryTelemetry
) {

    @SuppressLint("MissingPermission")
    fun startDiscovery(): Flow<List<DiscoveredDevice>> = callbackFlow {
        val discovered = mutableMapOf<String, DiscoveredDevice>()
        telemetry.recordDiscoveryStart(DiscoveryProtocol.BLUETOOTH)

        // 运行时权限检查：Android 12+ 需要 BLUETOOTH_SCAN；更早版本需要定位权限
        val hasRequired = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (!hasRequired) {
            telemetry.recordPermissionMissing(DiscoveryProtocol.BLUETOOTH, if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "BLUETOOTH_SCAN" else "ACCESS_FINE_LOCATION")
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        val btManager = context.getSystemService(android.content.Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter? = btManager.adapter
        val scanner: BluetoothLeScanner? = adapter?.bluetoothLeScanner

        if (adapter == null || !adapter.isEnabled || scanner == null) {
            close()
            return@callbackFlow
        }

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                result ?: return
                handleResult(result, discovered)
                trySend(discovered.values.toList())
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                results?.forEach {
                    handleResult(it, discovered)
                }
                trySend(discovered.values.toList())
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w("BleDiscovery", "Scan failed: $errorCode")
                telemetry.recordError(DiscoveryProtocol.BLUETOOTH, "BLE_SCAN_FAILED_$errorCode", null)
            }
        }

        try {
            scanner.startScan(callback)
        } catch (_: SecurityException) {
            telemetry.recordPermissionMissing(DiscoveryProtocol.BLUETOOTH, "BLUETOOTH_SCAN")
            trySend(emptyList())
            close()
            return@callbackFlow
        } catch (_: Exception) {
            trySend(emptyList())
            close()
            return@callbackFlow
        }

        awaitClose {
            try { scanner.stopScan(callback) } catch (_: Exception) {}
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleResult(result: ScanResult, discovered: MutableMap<String, DiscoveredDevice>) {
        val dev = result.device
        val record = result.scanRecord
        val name = record?.deviceName ?: dev.name ?: "BLE Device"
        val addr = dev.address ?: ""
        val id = "ble-$addr"
        val type = DeviceType.UNKNOWN

        val capabilities = mutableSetOf<DeviceCapability>()
        val uuids: List<ParcelUuid> = record?.serviceUuids ?: emptyList()
        if (uuids.isNotEmpty()) {
            capabilities.add(DeviceCapability.REMOTE_CONTROL)
        }

        val updated = DiscoveredDevice(
            id = id,
            name = name,
            type = type,
            capabilities = if (capabilities.isEmpty()) setOf(DeviceCapability.REMOTE_CONTROL) else capabilities,
            connectionInfo = ConnectionInfo(
                protocol = DiscoveryProtocol.BLUETOOTH,
                address = addr,
                port = 0,
                serviceType = null,
                txtRecords = emptyMap(),
                preferredConnect = PreferredConnect.BLE,
                version = null,
                extra = mapOf(
                    "uuid_count" to (uuids.size).toString(),
                    "has_manufacturer_data" to (record?.manufacturerSpecificData?.size() ?: 0).toString()
                )
            ),
            signalStrength = result.rssi,
            lastSeen = System.currentTimeMillis()
        )

        discovered[id] = updated
        telemetry.recordDeviceDiscovered(DiscoveryProtocol.BLUETOOTH, id)
    }
}