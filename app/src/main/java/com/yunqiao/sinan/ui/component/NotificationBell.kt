package com.yunqiao.sinan.ui.component

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.yunqiao.sinan.data.notification.SystemNotification

@Composable
fun NotificationBell(
    notifications: List<SystemNotification>,
    onMarkAllRead: () -> Unit,
    onNotificationRead: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }
    val unreadCount = notifications.count { !it.isRead }
    Box(modifier = modifier) {
        BadgedBox(
            badge = {
                if (unreadCount > 0) {
                    Badge {
                        Text(text = unreadCount.coerceAtMost(99).toString())
                    }
                }
            }
        ) {
            IconButton(
                onClick = {
                    expanded = !expanded
                    if (!expanded) {
                        onMarkAllRead()
                    }
                }
            ) {
                Icon(imageVector = Icons.Default.Notifications, contentDescription = "系统通知")
            }
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = {
                expanded = false
                onMarkAllRead()
            }
        ) {
            if (notifications.isEmpty()) {
                DropdownMenuItem(
                    text = { Text(text = "暂无消息") },
                    onClick = {
                        expanded = false
                    }
                )
            } else {
                Surface(
                    tonalElevation = 2.dp,
                    shape = CircleShape
                ) {
                    Column(
                        modifier = Modifier
                            .clip(MaterialTheme.shapes.large)
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(12.dp)
                            .height(320.dp)
                            .width(320.dp)
                    ) {
                        Text(text = "系统通知", style = MaterialTheme.typography.titleMedium)
                        Spacer(modifier = Modifier.height(12.dp))
                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            items(notifications.take(20)) { notification ->
                                NotificationItem(
                                    notification = notification,
                                    onClick = {
                                        onNotificationRead(notification.id)
                                        expanded = false
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun NotificationItem(
    notification: SystemNotification,
    onClick: () -> Unit
) {
    DropdownMenuItem(
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(text = notification.title, style = MaterialTheme.typography.titleSmall)
                    if (!notification.isRead) {
                        Surface(
                            color = MaterialTheme.colorScheme.primary,
                            shape = CircleShape
                        ) {
                            Text(
                                text = "未读",
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                                color = MaterialTheme.colorScheme.onPrimary,
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    }
                }
                Text(text = notification.message, style = MaterialTheme.typography.bodySmall)
            }
        },
        onClick = onClick
    )
}
