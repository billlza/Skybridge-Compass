package com.skybridge.compass.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.skybridge.compass.auth.NebulaOAuthCoordinator

/**
 * Transparent receiver for the Nebula OAuth redirect (`skybridge://auth/nebula`).
 *
 * The Android analogue of iOS's `ASWebAuthenticationSession` callback: Chrome Custom Tabs
 * redirects here, we hand the callback [android.net.Uri] to [NebulaOAuthCoordinator] (which
 * resumes the suspending OAuth flow), then immediately finish without showing any UI.
 *
 * `launchMode="singleTask"` + finishing keeps the existing MainActivity task intact so the
 * user lands back on the (now authenticated) app, not a fresh instance.
 */
class NebulaRedirectActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleRedirect(intent)
        finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleRedirect(intent)
        finish()
    }

    private fun handleRedirect(intent: Intent?) {
        val uri = intent?.data
        if (uri != null) {
            NebulaOAuthCoordinator.deliver(uri)
        }
        // Bring the app's main task back to the foreground so the user returns to the app.
        runCatching {
            val relaunch = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            startActivity(relaunch)
        }
    }
}
