package com.skybridge.compass.android.remote.host

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

object AndroidRemoteControlHostRuntime {
    sealed class State {
        data object Stopped : State()
        data class Starting(val message: String) : State()
        data class Running(
            val port: Int,
            val serviceName: String?,
            val captureWidth: Int,
            val captureHeight: Int,
            val connectedClients: Int,
            val inputEnabled: Boolean
        ) : State()
        data class Error(val message: String) : State()
    }

    private val _state = MutableStateFlow<State>(State.Stopped)
    val state: StateFlow<State> = _state.asStateFlow()

    internal fun update(state: State) {
        _state.value = state
    }
}
