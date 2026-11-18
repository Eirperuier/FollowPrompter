package com.reiureprie.followprompter.remote

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    @Test
    fun parsesStatusFromIPad() {
        // iPad 端 JSONEncoder 编码的 RemoteStatus（countdown 为 nil 时字段不存在）
        val line = """{"type":"status","status":{"title":"测试","mode":"voice","running":true,"listening":true,
            "progress":0.25,"elapsed":75,"current":"第一句。","next":"第二句。","rereadCount":2,"autoSpeed":60}}"""
            .replace("\n", "")
        val m = Protocol.parse(line) as Protocol.Message.Status
        assertEquals("测试", m.status.title)
        assertNull(m.status.countdown)
        assertEquals(0.25, m.status.progress, 1e-9)
        assertEquals("跟读中", m.status.stateText)
    }

    @Test
    fun countdownWins() {
        val m = Protocol.parse("""{"type":"status","status":{"mode":"auto","running":false,"countdown":3}}""") as Protocol.Message.Status
        assertEquals("倒数 3", m.status.stateText)
    }

    @Test
    fun encodesHelloAndCommands() {
        val hello = JSONObject(Protocol.hello("Pixel", "0420"))
        assertEquals("hello", hello.getString("type"))
        assertEquals("0420", hello.getString("code"))   // 前导 0 不能丢
        assertEquals("rereadSentence", JSONObject(Protocol.command(Command.RereadSentence)).getString("command"))
        assertTrue(Protocol.parse("""{"type":"denied","reason":"配对码不对"}""") is Protocol.Message.Denied)
        assertTrue(Protocol.parse("not json") == null)
    }
}
