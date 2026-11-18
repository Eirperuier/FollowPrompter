package com.reiureprie.followprompter.remote

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** 同一 Wi‑Fi 下找到的 iPad */
data class FoundHost(val name: String, val address: String, val port: Int)

/**
 * 用 NsdManager（mDNS / Bonjour）发现 iPad 广播的 _fpremote._tcp 服务。
 * resolveService 同一时间只能解析一个，所以排队逐个解析。
 */
class Discovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val main = Handler(Looper.getMainLooper())

    private val _hosts = MutableStateFlow<List<FoundHost>>(emptyList())
    val hosts: StateFlow<List<FoundHost>> = _hosts.asStateFlow()

    private var listener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    fun start() {
        if (listener != null) return
        multicastLock = wifi.createMulticastLock("FollowPrompterRemote").apply {
            setReferenceCounted(false)
            acquire()
        }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post { listener = null }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post { enqueue(info) }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                main.post { _hosts.value = _hosts.value.filterNot { it.name == info.serviceName } }
            }
        }
        listener = l
        runCatching { nsd.discoverServices(Protocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
            .onFailure { listener = null }
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        pending.clear()
        resolving = false
        _hosts.value = emptyList()
    }

    private fun enqueue(info: NsdServiceInfo) {
        if (pending.none { it.serviceName == info.serviceName }) pending.addLast(info)
        resolveNext()
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post {
                    resolving = false
                    resolveNext()
                }
            }

            override fun onServiceResolved(resolved: NsdServiceInfo) {
                main.post {
                    resolving = false
                    val address = resolved.host?.hostAddress
                    if (address != null) {
                        val host = FoundHost(resolved.serviceName, address, resolved.port)
                        _hosts.value = _hosts.value.filterNot { it.name == host.name } + host
                    }
                    resolveNext()
                }
            }
        })
    }
}
