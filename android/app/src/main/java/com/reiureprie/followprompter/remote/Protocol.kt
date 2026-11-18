package com.reiureprie.followprompter.remote

import org.json.JSONObject

/**
 * 和 iPad 的局域网遥控协议：一行一条 JSON（UTF-8，以 \n 结尾）。
 * 对应 iPad 端 FollowPrompter/Remote/LANRemoteServer.swift。
 */
object Protocol {
    const val SERVICE_TYPE = "_fpremote._tcp."
    const val DEFAULT_PORT = 52819
    const val VERSION = 1

    fun hello(name: String, code: String): String =
        JSONObject().put("type", "hello").put("name", name).put("code", code).put("version", VERSION).toString()

    fun command(c: Command): String = JSONObject().put("type", "command").put("command", c.wire).toString()

    val ping: String = JSONObject().put("type", "ping").toString()

    sealed interface Message {
        data class Welcome(val host: String) : Message
        data class Denied(val reason: String) : Message
        data class Status(val status: RemoteStatus) : Message
        data object Pong : Message
    }

    fun parse(line: String): Message? {
        val o = runCatching { JSONObject(line) }.getOrNull() ?: return null
        return when (o.optString("type")) {
            "welcome" -> Message.Welcome(o.optString("host", "iPad"))
            "denied" -> Message.Denied(o.optString("reason", "连接被拒绝"))
            "status" -> o.optJSONObject("status")?.let { Message.Status(RemoteStatus.from(it)) }
            "pong" -> Message.Pong
            else -> null
        }
    }
}

/** 命令名和 iPad 端 RemoteCommand 的 rawValue 一致 */
enum class Command(val wire: String) {
    Toggle("toggle"),
    RereadSentence("rereadSentence"),
    RereadParagraph("rereadParagraph"),
    PreviousSentence("previousSentence"),
    NextSentence("nextSentence"),
    Restart("restart"),
    Faster("faster"),
    Slower("slower"),
}

data class RemoteStatus(
    val title: String,
    val mode: String,          // voice / auto / manual
    val running: Boolean,
    val countdown: Int?,
    val listening: Boolean,
    val progress: Double,
    val elapsed: Int,
    val current: String,
    val next: String,
    val rereadCount: Int,
    val autoSpeed: Int,
) {
    val modeTitle: String
        get() = when (mode) {
            "voice" -> "跟读"
            "auto" -> "匀速"
            "manual" -> "手动"
            else -> ""
        }

    val stateText: String
        get() = countdown?.let { "倒数 $it" } ?: if (running) "${modeTitle}中" else "已暂停"

    companion object {
        fun from(o: JSONObject) = RemoteStatus(
            title = o.optString("title"),
            mode = o.optString("mode"),
            running = o.optBoolean("running"),
            countdown = if (o.has("countdown") && !o.isNull("countdown")) o.optInt("countdown") else null,
            listening = o.optBoolean("listening"),
            progress = o.optDouble("progress", 0.0).coerceIn(0.0, 1.0),
            elapsed = o.optInt("elapsed"),
            current = o.optString("current"),
            next = o.optString("next"),
            rereadCount = o.optInt("rereadCount"),
            autoSpeed = o.optInt("autoSpeed"),
        )
    }
}
