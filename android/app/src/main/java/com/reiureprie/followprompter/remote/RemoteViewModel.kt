package com.reiureprie.followprompter.remote

import android.app.Application
import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 要连接的 iPad：自动发现的，或手动输入地址的 */
data class Target(val name: String, val address: String, val port: Int, val manual: Boolean) {
    val key: String get() = if (manual) "$address:$port" else name
}

sealed interface Phase {
    data object Searching : Phase
    data class Connecting(val target: Target) : Phase
    data class Connected(val hostName: String, val target: Target) : Phase
}

data class CodePrompt(val target: Target, val wrong: Boolean)

data class UiState(
    val hosts: List<FoundHost> = emptyList(),
    val phase: Phase = Phase.Searching,
    val status: RemoteStatus? = null,
    val codePrompt: CodePrompt? = null,
    val message: String? = null,
    val volumeKeys: Boolean = true,
)

class RemoteViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("remote", Context.MODE_PRIVATE)
    private val discovery = Discovery(app)
    private val deviceName: String =
        Settings.Global.getString(app.contentResolver, "device_name")?.takeIf { it.isNotBlank() } ?: Build.MODEL

    private val _state = MutableStateFlow(UiState(volumeKeys = prefs.getBoolean("volumeKeys", true)))
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var session: RemoteSession? = null
    private var job: Job? = null
    /** 用户主动断开后不再自动连接，直到他再点一次 */
    private var autoConnect = true
    private var active = false

    init {
        viewModelScope.launch {
            discovery.hosts.collect { hosts ->
                _state.update { it.copy(hosts = hosts) }
                maybeAutoConnect()
            }
        }
    }

    // MARK: 生命周期（App 在前台时才搜索和连接，和 iPhone 遥控器一致）

    fun resume() {
        if (active) return
        active = true
        discovery.start()
        lastManual()?.let { if (autoConnect && prefs.getString("lastHost", null) == it.key) connectOrAsk(it) }
    }

    fun pause() {
        active = false
        job?.cancel()
        job = null
        session = null
        discovery.stop()
        _state.update { it.copy(phase = Phase.Searching, status = null) }
    }

    // MARK: 用户操作

    fun choose(host: FoundHost) {
        autoConnect = true
        connectOrAsk(Target(host.name, host.address, host.port, manual = false))
    }

    fun connectManually(input: String) {
        val text = input.trim()
        val (address, port) = text.substringBeforeLast(":", text).let { addr ->
            val p = if (text.contains(":")) text.substringAfterLast(":").toIntOrNull() ?: -1 else Protocol.DEFAULT_PORT
            addr to p
        }
        if (address.isBlank() || port !in 1..65535 || address.any { it.isWhitespace() }) {
            _state.update { it.copy(message = "地址格式不对，应该像 192.168.1.5:52819") }
            return
        }
        val target = Target(address, address, port, manual = true)
        prefs.edit().putString("manualAddress", "$address:$port").apply()
        autoConnect = true
        connectOrAsk(target)
    }

    fun submitCode(code: String) {
        val prompt = _state.value.codePrompt ?: return
        _state.update { it.copy(codePrompt = null) }
        connect(prompt.target, code.trim())
    }

    fun dismissCodePrompt() {
        _state.update { it.copy(codePrompt = null) }
        autoConnect = false
    }

    fun disconnect() {
        autoConnect = false
        job?.cancel()
        job = null
        session = null
        _state.update { it.copy(phase = Phase.Searching, status = null) }
    }

    fun send(command: Command) {
        session?.send(command)
    }

    fun setVolumeKeys(on: Boolean) {
        prefs.edit().putBoolean("volumeKeys", on).apply()
        _state.update { it.copy(volumeKeys = on) }
    }

    val isConnected: Boolean get() = _state.value.phase is Phase.Connected

    fun savedManualAddress(): String = prefs.getString("manualAddress", null) ?: ""

    // MARK: 连接

    private fun maybeAutoConnect() {
        val s = _state.value
        if (!active || !autoConnect || s.phase != Phase.Searching || s.codePrompt != null) return
        val last = prefs.getString("lastHost", null)
        val host = s.hosts.firstOrNull { it.name == last }
            ?: s.hosts.singleOrNull()
            ?: return
        connectOrAsk(Target(host.name, host.address, host.port, manual = false))
    }

    private fun connectOrAsk(target: Target) {
        val code = prefs.getString("code:${target.key}", null)
        if (code != null) connect(target, code)
        else _state.update { it.copy(codePrompt = CodePrompt(target, wrong = false), message = null) }
    }

    private fun connect(target: Target, code: String) {
        job?.cancel()
        val s = RemoteSession(target.address, target.port, code, deviceName)
        session = s
        _state.update { it.copy(phase = Phase.Connecting(target), status = null, message = null) }
        var everConnected = false
        var denied = false
        job = viewModelScope.launch {
            s.run { event ->
                when (event) {
                    is RemoteSession.Event.Welcome -> {
                        everConnected = true
                        prefs.edit()
                            .putString("code:${target.key}", code)
                            .putString("code:${event.host}", code)
                            .putString("lastHost", target.key)
                            .apply()
                        _state.update { it.copy(phase = Phase.Connected(event.host, target)) }
                    }
                    is RemoteSession.Event.Denied -> {
                        denied = true
                        prefs.edit().remove("code:${target.key}").apply()
                        _state.update { it.copy(codePrompt = CodePrompt(target, wrong = true)) }
                    }
                    is RemoteSession.Event.Status -> _state.update { it.copy(status = event.status) }
                    is RemoteSession.Event.Closed -> {
                        if (session === s) session = null
                        _state.update {
                            it.copy(
                                phase = Phase.Searching, status = null,
                                message = if (!everConnected && !denied) event.error else null,
                            )
                        }
                    }
                }
            }
            // 断线（iPad 退出提词页、网络抖动）后自动重连
            if (!denied && autoConnect && active) {
                delay(if (everConnected) 1000 else 3000)
                val still = target.manual || _state.value.hosts.any { it.name == target.name }
                if (still && _state.value.phase == Phase.Searching && _state.value.codePrompt == null) {
                    connect(target, code)
                } else {
                    maybeAutoConnect()
                }
            }
        }
    }

    private fun lastManual(): Target? {
        val saved = prefs.getString("manualAddress", null) ?: return null
        val address = saved.substringBeforeLast(":")
        val port = saved.substringAfterLast(":").toIntOrNull() ?: return null
        return Target(address, address, port, manual = true)
    }

    override fun onCleared() {
        discovery.stop()
        job?.cancel()
    }
}
