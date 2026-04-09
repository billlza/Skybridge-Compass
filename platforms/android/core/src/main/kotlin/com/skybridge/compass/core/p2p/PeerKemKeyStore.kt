@file:Suppress("DEPRECATION")

package com.skybridge.compass.core.p2p

import android.content.Context
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.skybridge.compass.shared.p2p.P2PCryptoSuite
import dagger.hilt.android.qualifiers.ApplicationContext
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PeerKemKeyStore @Inject constructor(
    @param:ApplicationContext private val appContext: Context
) {
    data class PeerKemPublicKeys(
        val xWingPublicKey: ByteArray? = null,
        val mlKem768PublicKey: ByteArray? = null
    )

    private val prefs by lazy {
        EncryptedSharedPreferences.create(
            appContext,
            PREFS_NAME,
            MasterKey.Builder(appContext).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun load(peerId: String): PeerKemPublicKeys {
        val h = peerId.sha256Key()
        val xwing = prefs.getString("xwing_$h", null)?.let { Base64.decode(it, Base64.DEFAULT) }
        val mlkem = prefs.getString("mlkem768_$h", null)?.let { Base64.decode(it, Base64.DEFAULT) }
        return PeerKemPublicKeys(xWingPublicKey = xwing, mlKem768PublicKey = mlkem)
    }

    fun save(peerId: String, kemPublicKeys: List<AppMessage.KemPublicKeyInfo>) {
        val h = peerId.sha256Key()
        var xwing: ByteArray? = null
        var mlkem: ByteArray? = null
        for (k in kemPublicKeys) {
            when (k.suiteWireId) {
                P2PCryptoSuite.X_WING.wireId.toInt() -> xwing = k.publicKey
                P2PCryptoSuite.MLKEM_768.wireId.toInt(),
                P2PCryptoSuite.MLKEM_768_FS_COMPAT.wireId.toInt() -> mlkem = k.publicKey
            }
        }
        prefs.edit().apply {
            if (xwing != null) putString("xwing_$h", Base64.encodeToString(xwing, Base64.NO_WRAP))
            if (mlkem != null) putString("mlkem768_$h", Base64.encodeToString(mlkem, Base64.NO_WRAP))
            putLong("updated_at_$h", System.currentTimeMillis())
            apply()
        }
    }

    private fun String.sha256Key(): String {
        val d = MessageDigest.getInstance("SHA-256").digest(toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    companion object {
        private const val PREFS_NAME = "skybridge_peer_kem_keys"
    }
}
