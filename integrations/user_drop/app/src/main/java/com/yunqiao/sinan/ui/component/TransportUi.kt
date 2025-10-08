package com.yunqiao.sinan.ui.component

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Nfc
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.manager.BridgeDevice
import com.yunqiao.sinan.manager.BridgeTransport
import com.yunqiao.sinan.manager.BridgeTransportHint
import androidx.compose.ui.graphics.vector.ImageVector

@Composable
fun TransportBadge(
    transport: BridgeTransport,
    modifier: Modifier = Modifier
) {
    AssistChip(
        onClick = {},
        modifier = modifier,
        leadingIcon = {
            Icon(
                imageVector = transport.icon(),
                contentDescription = null,
                tint = transport.tint()
            )
        },
        label = {
            Column {
                Text(
                    text = transport.label(),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color.White
                )
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = transport.description(),
                    fontSize = 10.sp,
                    color = Color.White.copy(alpha = 0.72f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        },
        colors = AssistChipDefaults.assistChipColors(containerColor = transport.tint().copy(alpha = 0.16f))
    )
}

@Composable
fun MetricChip(
    label: String,
    value: String,
    icon: ImageVector,
    modifier: Modifier = Modifier
) {
    AssistChip(
        onClick = {},
        modifier = modifier,
        leadingIcon = {
            Icon(imageVector = icon, contentDescription = null, tint = Color.White)
        },
        label = {
            Text(
                text = "$label $value",
                color = Color.White,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        },
        colors = AssistChipDefaults.assistChipColors(containerColor = Color.White.copy(alpha = 0.08f))
    )
}

fun BridgeTransport.label(): String = when (this) {
    is BridgeTransport.DirectHotspot -> when (medium) {
        BridgeTransportHint.UltraWideband -> "液态直连"
        BridgeTransportHint.Bluetooth -> "蓝牙桥接"
        BridgeTransportHint.Nfc -> "NFC 接力"
        BridgeTransportHint.UniversalBridge -> "跨端直连"
        else -> "热点直连"
    }
    is BridgeTransport.Peripheral -> when (medium) {
        BridgeTransportHint.Bluetooth -> "蓝牙同步"
        BridgeTransportHint.Nfc -> "近场快传"
        BridgeTransportHint.AirPlay -> "AirPlay 镜像"
        BridgeTransportHint.UniversalBridge -> "多端协作"
        else -> "近场外设"
    }
    is BridgeTransport.LocalLan -> "局域网通道"
    is BridgeTransport.CloudRelay -> "云桥中继"
}

fun BridgeTransport.description(): String = when (this) {
    is BridgeTransport.DirectHotspot -> when (medium) {
        BridgeTransportHint.UltraWideband -> "近距离无损镜像，硬件级低延迟"
        BridgeTransportHint.Bluetooth -> "蓝牙信道直连，自动降噪编码"
        BridgeTransportHint.Nfc -> "贴近即连，瞬时高安全握手"
        BridgeTransportHint.UniversalBridge -> "全终端互通，一键同屏同传"
        else -> "端对端免外网，硬件加速编码"
    }
    is BridgeTransport.Peripheral -> when (medium) {
        BridgeTransportHint.Bluetooth -> "穿戴/车机联动，文件秒传"
        BridgeTransportHint.Nfc -> "碰一碰快速配对传输"
        BridgeTransportHint.AirPlay -> "兼容 AirPlay 协议的跨端镜像"
        BridgeTransportHint.UniversalBridge -> "混合协议聚合，适配全平台"
        else -> "近场外设互通"
    }
    is BridgeTransport.LocalLan -> "同网段高速互访"
    is BridgeTransport.CloudRelay -> "跨区域账号互联"
}

fun BridgeTransport.tint(): Color = when (this) {
    is BridgeTransport.DirectHotspot -> when (medium) {
        BridgeTransportHint.UltraWideband -> Color(0xFFFFC400)
        BridgeTransportHint.Bluetooth -> Color(0xFF3D5AFE)
        BridgeTransportHint.Nfc -> Color(0xFF00BFA5)
        BridgeTransportHint.UniversalBridge -> Color(0xFF8E24AA)
        else -> Color(0xFF00E5FF)
    }
    is BridgeTransport.Peripheral -> when (medium) {
        BridgeTransportHint.Bluetooth -> Color(0xFF536DFE)
        BridgeTransportHint.Nfc -> Color(0xFF26A69A)
        BridgeTransportHint.AirPlay -> Color(0xFF7E57C2)
        BridgeTransportHint.UniversalBridge -> Color(0xFF8E24AA)
        else -> Color(0xFF5C6BC0)
    }
    is BridgeTransport.LocalLan -> Color(0xFF4CAF50)
    is BridgeTransport.CloudRelay -> Color(0xFF7E57C2)
}

fun BridgeTransport.icon(): ImageVector = when (this) {
    is BridgeTransport.DirectHotspot -> when (medium) {
        BridgeTransportHint.UltraWideband -> Icons.Default.WifiTethering
        BridgeTransportHint.Bluetooth -> Icons.Default.Bluetooth
        BridgeTransportHint.Nfc -> Icons.Default.Nfc
        BridgeTransportHint.UniversalBridge -> Icons.Default.WifiTethering
        else -> Icons.Default.WifiTethering
    }
    is BridgeTransport.Peripheral -> when (medium) {
        BridgeTransportHint.Bluetooth -> Icons.Default.Bluetooth
        BridgeTransportHint.Nfc -> Icons.Default.Nfc
        BridgeTransportHint.AirPlay -> Icons.Default.Cast
        BridgeTransportHint.UniversalBridge -> Icons.Default.Cast
        else -> Icons.Default.Cast
    }
    is BridgeTransport.LocalLan -> Icons.Default.Cable
    is BridgeTransport.CloudRelay -> Icons.Default.Cloud
}

fun BridgeTransport.portDisplay(): String = when (this) {
    is BridgeTransport.DirectHotspot -> port.toString()
    is BridgeTransport.LocalLan -> port.toString()
    is BridgeTransport.CloudRelay -> negotiatedPort.toString()
    is BridgeTransport.Peripheral -> channel.toString()
}

fun transportTintForCapability(device: BridgeDevice): Color {
    return when {
        BridgeTransportHint.UltraWideband in device.capabilities -> Color(0xFFFFC400)
        BridgeTransportHint.Bluetooth in device.capabilities -> Color(0xFF3D5AFE)
        BridgeTransportHint.Nfc in device.capabilities -> Color(0xFF26A69A)
        BridgeTransportHint.AirPlay in device.capabilities -> Color(0xFF7E57C2)
        BridgeTransportHint.UniversalBridge in device.capabilities -> Color(0xFF8E24AA)
        BridgeTransportHint.WifiDirect in device.capabilities -> Color(0xFF00E5FF)
        BridgeTransportHint.Lan in device.capabilities -> Color(0xFF4CAF50)
        else -> Color(0xFF7E57C2)
    }
}
