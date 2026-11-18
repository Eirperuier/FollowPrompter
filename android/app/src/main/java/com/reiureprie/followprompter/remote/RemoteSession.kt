package com.reiureprie.followprompter.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.BufferedWriter
import java.net.InetSocketAddress
import java.net.Socket

/**
 * 一次 TCP 连接：发 hello → 收 welcome / denied → 收状态、发命令。
 * 每 3 秒 ping 一次；iPad 每次都会回 pong，所以 10 秒读不到任何东西就认为断了。
 */
class RemoteSession(
    private val address: String,
    private val port: Int,
    private val code: String,
    private val deviceName: String,
) {
    sealed interface Event {
        data class Welcome(val host: String) : Event
        data class Denied(val reason: String) : Event
        data class Status(val status: RemoteStatus) : Event
        data class Closed(val error: String?) : Event
    }

    private val outgoing = Channel<String>(Channel.UNLIMITED)

    fun send(command: Command) {
        outgoing.trySend(Protocol.command(command))
    }

    /** 阻塞直到连接结束；事件在调用方的协程上下文里回调 */
    suspend fun run(onEvent: (Event) -> Unit) {
        val socket = Socket()
        var error: String? = null
        try {
            withContext(Dispatchers.IO) {
                socket.connect(InetSocketAddress(address, port), 4000)
                socket.soTimeout = 10_000
                socket.tcpNoDelay = true
            }
            val writer = socket.getOutputStream().bufferedWriter(Charsets.UTF_8)
            val reader = socket.getInputStream().bufferedReader(Charsets.UTF_8)
            coroutineScope {
                val scope: CoroutineScope = this
                val out = launch(Dispatchers.IO) {
                    write(writer, Protocol.hello(deviceName, code))
                    for (line in outgoing) write(writer, line)
                }
                val pinger = launch {
                    while (isActive) {
                        delay(3000)
                        outgoing.trySend(Protocol.ping)
                    }
                }
                while (scope.isActive) {
                    val line = withContext(Dispatchers.IO) { reader.readLine() } ?: break
                    when (val m = Protocol.parse(line)) {
                        is Protocol.Message.Welcome -> onEvent(Event.Welcome(m.host))
                        is Protocol.Message.Denied -> {
                            onEvent(Event.Denied(m.reason))
                            break
                        }
                        is Protocol.Message.Status -> onEvent(Event.Status(m.status))
                        Protocol.Message.Pong, null -> {}
                    }
                }
                out.cancel()
                pinger.cancel()
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            error = when (e) {
                is java.net.SocketTimeoutException -> "连接超时"
                is java.net.ConnectException -> "连不上（iPad 是否打开了提词页面？）"
                else -> e.localizedMessage ?: e.javaClass.simpleName
            }
        } finally {
            outgoing.close()
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) { runCatching { socket.close() } }
        }
        onEvent(Event.Closed(error))
    }

    private fun write(writer: BufferedWriter, line: String) {
        writer.write(line)
        writer.write("\n")
        writer.flush()
    }
}
