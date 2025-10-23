package com.yunqiao.sinan.data.auth

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames

@Serializable
data class UserAccount(
    val phoneNumber: String?,
    val email: String?,
    val starAccount: String?,
    val googleAccount: String?,
    val passwordHash: String,
    @SerialName("nubulaId")
    @JsonNames("starId", "nebulaId")
    val nubulaId: Long,
    val tier: AccountTier = AccountTier.STANDARD,
    val createdAt: Long
)

@Serializable
enum class AccountTier {
    @SerialName("standard")
    STANDARD,
    @SerialName("premium")
    PREMIUM,
    @SerialName("elite")
    ELITE
}

enum class LoginMethod {
    PHONE,
    EMAIL,
    STAR_ACCOUNT,
    GOOGLE
}

data class RegistrationRequest(
    val phoneNumber: String?,
    val email: String?,
    val starAccount: String?,
    val googleAccount: String?,
    val password: String,
    val tier: AccountTier = AccountTier.STANDARD
)
