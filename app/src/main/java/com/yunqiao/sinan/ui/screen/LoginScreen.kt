package com.yunqiao.sinan.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.yunqiao.sinan.data.auth.AccountTier
import com.yunqiao.sinan.data.auth.LoginMethod
import com.yunqiao.sinan.data.auth.RegistrationRequest
import com.yunqiao.sinan.data.auth.UserAccount
import com.yunqiao.sinan.manager.UserAccountManager
import kotlinx.coroutines.launch

@Composable
fun LoginScreen(
    userAccountManager: UserAccountManager,
    onAuthenticated: (UserAccount) -> Unit,
    modifier: Modifier = Modifier
) {
    val scope = rememberCoroutineScope()
    var isLoginMode by remember { mutableStateOf(true) }
    var selectedMethod by remember { mutableStateOf(LoginMethod.PHONE) }
    var phoneNumber by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var starAccount by remember { mutableStateOf("") }
    var googleAccount by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirmPassword by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var feedback by remember { mutableStateOf<String?>(null) }
    var registrationSuccess by remember { mutableStateOf<String?>(null) }
    var selectedTier by remember { mutableStateOf(AccountTier.STANDARD) }

    LaunchedEffect(Unit) {
        val currentUser = userAccountManager.currentUser.value
        if (currentUser != null) {
            onAuthenticated(currentUser)
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.9f),
                        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.6f)
                    )
                )
            ),
        contentAlignment = Alignment.Center
    ) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp),
            shape = RoundedCornerShape(28.dp),
            colors = CardDefaults.cardColors(MaterialTheme.colorScheme.surface.copy(alpha = 0.95f))
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(28.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp)
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(text = "欢迎使用云桥司南", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    Text(text = "请登录或注册以继续", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(onClick = {
                        isLoginMode = true
                        feedback = null
                        registrationSuccess = null
                    }) {
                        Text(text = "登录", fontWeight = if (isLoginMode) FontWeight.Bold else FontWeight.Normal)
                    }
                    TextButton(onClick = {
                        isLoginMode = false
                        feedback = null
                        registrationSuccess = null
                    }) {
                        Text(text = "注册", fontWeight = if (!isLoginMode) FontWeight.Bold else FontWeight.Normal)
                    }
                }
                if (isLoginMode) {
                    LoginForm(
                        selectedMethod = selectedMethod,
                        onMethodChange = { method ->
                            selectedMethod = method
                            feedback = null
                        },
                        phoneNumber = phoneNumber,
                        email = email,
                        starAccount = starAccount,
                        googleAccount = googleAccount,
                        password = password,
                        onPhoneChange = { phoneNumber = it },
                        onEmailChange = { email = it },
                        onStarAccountChange = { starAccount = it },
                        onGoogleAccountChange = { googleAccount = it },
                        onPasswordChange = { password = it }
                    )
                    Button(
                        onClick = {
                            feedback = null
                            registrationSuccess = null
                            loading = true
                            scope.launch {
                                val identifier = when (selectedMethod) {
                                    LoginMethod.PHONE -> phoneNumber
                                    LoginMethod.EMAIL -> email
                                    LoginMethod.STAR_ACCOUNT -> if (starAccount.isNotBlank()) starAccount else phoneNumber.ifBlank { email }
                                    LoginMethod.GOOGLE -> googleAccount.ifBlank { email }
                                }
                                if (identifier.isBlank()) {
                                    loading = false
                                    feedback = "请输入有效账号"
                                    return@launch
                                }
                                runCatching {
                                    userAccountManager.authenticate(selectedMethod, identifier, password)
                                }.onSuccess { account ->
                                    loading = false
                                    onAuthenticated(account)
                                }.onFailure { throwable ->
                                    loading = false
                                    feedback = throwable.message ?: "登录失败"
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !loading && password.isNotBlank()
                    ) {
                        if (loading) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp))
                        } else {
                            Text(text = "立即登录")
                        }
                    }
                } else {
                    RegistrationForm(
                        phoneNumber = phoneNumber,
                        email = email,
                        starAccount = starAccount,
                        googleAccount = googleAccount,
                        password = password,
                        confirmPassword = confirmPassword,
                        onPhoneChange = { phoneNumber = it },
                        onEmailChange = { email = it },
                        onStarAccountChange = { starAccount = it },
                        onGoogleAccountChange = { googleAccount = it },
                        onPasswordChange = { password = it },
                        onConfirmPasswordChange = { confirmPassword = it },
                        selectedTier = selectedTier,
                        onTierChange = { selectedTier = it }
                    )
                    Button(
                        onClick = {
                            feedback = null
                            registrationSuccess = null
                            if (password != confirmPassword) {
                                feedback = "两次密码输入不一致"
                                return@Button
                            }
                            loading = true
                            scope.launch {
                                runCatching {
                                    val request = RegistrationRequest(
                                        phoneNumber = phoneNumber.ifBlank { null },
                                        email = email.ifBlank { null },
                                        starAccount = starAccount.ifBlank { null },
                                        googleAccount = googleAccount.ifBlank { null },
                                        password = password,
                                        tier = selectedTier
                                    )
                                    userAccountManager.registerAccount(request)
                                }.onSuccess { account ->
                                    loading = false
                                    registrationSuccess = "注册成功，nubula ID ${account.nubulaId}"
                                    onAuthenticated(account)
                                }.onFailure { throwable ->
                                    loading = false
                                    feedback = throwable.message ?: "注册失败"
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !loading && password.isNotBlank() && confirmPassword.isNotBlank()
                    ) {
                        if (loading) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp))
                        } else {
                            Text(text = "立即注册")
                        }
                    }
                }
                if (!feedback.isNullOrBlank()) {
                    Surface(
                        color = MaterialTheme.colorScheme.errorContainer,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = feedback ?: "",
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.padding(12.dp)
                        )
                    }
                }
                if (!registrationSuccess.isNullOrBlank()) {
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = registrationSuccess ?: "",
                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                            modifier = Modifier.padding(12.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LoginForm(
    selectedMethod: LoginMethod,
    onMethodChange: (LoginMethod) -> Unit,
    phoneNumber: String,
    email: String,
    starAccount: String,
    googleAccount: String,
    password: String,
    onPhoneChange: (String) -> Unit,
    onEmailChange: (String) -> Unit,
    onStarAccountChange: (String) -> Unit,
    onGoogleAccountChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LoginMethod.values().forEach { method ->
                FilterChip(
                    selected = method == selectedMethod,
                    onClick = { onMethodChange(method) },
                    label = {
                        val label = when (method) {
                            LoginMethod.PHONE -> "手机号"
                            LoginMethod.EMAIL -> "邮箱"
                            LoginMethod.STAR_ACCOUNT -> "星云账号"
                            LoginMethod.GOOGLE -> "Google"
                        }
                        Text(text = label)
                    }
                )
            }
        }
        when (selectedMethod) {
            LoginMethod.PHONE -> {
                OutlinedTextField(
                    value = phoneNumber,
                    onValueChange = onPhoneChange,
                    label = { Text(text = "手机号") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone)
                )
            }
            LoginMethod.EMAIL -> {
                OutlinedTextField(
                    value = email,
                    onValueChange = onEmailChange,
                    label = { Text(text = "邮箱账号") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email)
                )
            }
            LoginMethod.STAR_ACCOUNT -> {
                OutlinedTextField(
                    value = starAccount,
                    onValueChange = onStarAccountChange,
                    label = { Text(text = "星云账号或ID") },
                    singleLine = true
                )
            }
            LoginMethod.GOOGLE -> {
                OutlinedTextField(
                    value = googleAccount,
                    onValueChange = onGoogleAccountChange,
                    label = { Text(text = "Google账号") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email)
                )
            }
        }
        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChange,
            label = { Text(text = "密码") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation()
        )
    }
}

@Composable
private fun RegistrationForm(
    phoneNumber: String,
    email: String,
    starAccount: String,
    googleAccount: String,
    password: String,
    confirmPassword: String,
    onPhoneChange: (String) -> Unit,
    onEmailChange: (String) -> Unit,
    onStarAccountChange: (String) -> Unit,
    onGoogleAccountChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onConfirmPasswordChange: (String) -> Unit,
    selectedTier: AccountTier,
    onTierChange: (AccountTier) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedTextField(
            value = phoneNumber,
            onValueChange = onPhoneChange,
            label = { Text(text = "手机号") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone)
        )
        OutlinedTextField(
            value = email,
            onValueChange = onEmailChange,
            label = { Text(text = "邮箱账号") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email)
        )
        OutlinedTextField(
            value = starAccount,
            onValueChange = onStarAccountChange,
            label = { Text(text = "自定义星云账号") },
            singleLine = true
        )
        OutlinedTextField(
            value = googleAccount,
            onValueChange = onGoogleAccountChange,
            label = { Text(text = "Google账号") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email)
        )
        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChange,
            label = { Text(text = "密码") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation()
        )
        OutlinedTextField(
            value = confirmPassword,
            onValueChange = onConfirmPasswordChange,
            label = { Text(text = "确认密码") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation()
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TierChip(label = "标准用户", tier = AccountTier.STANDARD, selectedTier = selectedTier, onTierChange = onTierChange)
            TierChip(label = "进阶会员", tier = AccountTier.PREMIUM, selectedTier = selectedTier, onTierChange = onTierChange)
            TierChip(label = "企业旗舰", tier = AccountTier.ELITE, selectedTier = selectedTier, onTierChange = onTierChange)
        }
    }
}

@Composable
private fun TierChip(
    label: String,
    tier: AccountTier,
    selectedTier: AccountTier,
    onTierChange: (AccountTier) -> Unit
) {
    FilterChip(
        selected = selectedTier == tier,
        onClick = { onTierChange(tier) },
        label = { Text(text = label) }
    )
}
