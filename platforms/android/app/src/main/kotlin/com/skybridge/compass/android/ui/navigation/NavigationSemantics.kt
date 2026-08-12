package com.skybridge.compass.android.ui.navigation

/** Stable UI-automation identifiers derived from navigation contracts, not localized copy. */
internal object NavigationSemantics {
    const val DASHBOARD_SCROLL = "dashboard:scroll"
    const val DASHBOARD_TITLE = "dashboard:title"
    const val DASHBOARD_DISCOVERY_STAT = "dashboard:stat:discovery-connections"
    const val DASHBOARD_TRANSFER_STAT = "dashboard:stat:transfers-performance"
    const val ACTION_SCAN_NETWORK = "scan-network"
    const val ACTION_SEND_FILE = "send-file"
    const val ACTION_REMOTE_DESKTOP = "remote-desktop"
    const val ACTION_CROSS_NETWORK = "cross-network"

    fun bottomTab(route: String): String = "navigation:tab:$route"

    fun destination(route: String): String = "navigation:destination:$route"

    fun dashboardAction(actionId: String, route: String): String =
        "dashboard:action:$actionId:$route"
}
