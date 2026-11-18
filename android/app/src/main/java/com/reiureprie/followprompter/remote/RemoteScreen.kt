package com.reiureprie.followprompter.remote

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Tablet
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val Red = Color(0xFFFF453A)
private val Orange = Color(0xFFFF9F0A)
private val Green = Color(0xFF30D158)
private val Gray = Color(0xFF636366)
private val Blue = Color(0xFF0A84FF)
private val Card = Color(0xFF1C1C1E)
private val Secondary = Color(0xFF98989F)

@Composable
fun RemoteScreen(vm: RemoteViewModel) {
    val state by vm.state.collectAsState()
    MaterialTheme(colorScheme = darkColorScheme(primary = Orange, background = Color.Black, surface = Card)) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .safeDrawingPadding()
                .padding(horizontal = 16.dp)
        ) {
            Column(Modifier.fillMaxSize()) {
                Text(
                    "遥控器", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp), textAlign = TextAlign.Center
                )
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    ConnectionHeader(state, vm)
                    StatusCard(state)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("音量键遥控（下 = 重读本句，上 = 开始 / 暂停）", color = Secondary, fontSize = 13.sp,
                            modifier = Modifier.weight(1f))
                        Switch(checked = state.volumeKeys, onCheckedChange = vm::setVolumeKeys)
                    }
                }
                // 没连上时把空间留给搜索 / 手动连接（键盘弹出时按钮会挤掉输入框）
                if (state.phase !is Phase.Searching) {
                    Controls(state, vm)
                    Spacer(Modifier.height(12.dp))
                }
            }
            state.codePrompt?.let { CodeDialog(it, vm) }
        }
    }
}

// MARK: 连接状态

@Composable
private fun ConnectionHeader(state: UiState, vm: RemoteViewModel) {
    when (val phase = state.phase) {
        is Phase.Connected -> Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(Green, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text("已连接 ${phase.hostName}", color = Color.White, fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            TextButton(onClick = vm::disconnect) { Text("断开") }
        }
        else -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Secondary)
                Spacer(Modifier.width(10.dp))
                Text(
                    if (phase is Phase.Connecting) "正在连接 ${phase.target.name}…" else "正在寻找 iPad…",
                    color = Color.White, fontWeight = FontWeight.Medium
                )
            }
            state.message?.let { Text(it, color = Red, fontSize = 13.sp) }
            if (phase !is Phase.Connecting) {
                state.hosts.forEach { host ->
                    OutlinedButton(onClick = { vm.choose(host) }, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Filled.Tablet, null)
                        Spacer(Modifier.width(8.dp))
                        Text(host.name, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            Text(
                "在 iPad 上打开任意稿件的提词页面，手机和 iPad 连同一个 Wi‑Fi 即可自动找到。第一次连接需要输入 iPad 上显示的配对码（提词页底部的手机图标里）。",
                color = Secondary, fontSize = 13.sp
            )
            ManualConnect(vm)
        }
    }
}

@Composable
private fun ManualConnect(vm: RemoteViewModel) {
    var open by remember { mutableStateOf(false) }
    var text by remember { mutableStateOf(vm.savedManualAddress()) }
    if (!open) {
        TextButton(onClick = { open = true }) { Text("找不到？手动输入地址") }
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = text, onValueChange = { text = it }, singleLine = true,
            label = { Text("iPad 地址，如 192.168.1.5:52819") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { if (text.isNotBlank()) { vm.connectManually(text); open = false } }),
            modifier = Modifier.fillMaxWidth()
        )
        Row {
            TextButton(onClick = { open = false }) { Text("取消") }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { vm.connectManually(text); open = false }, enabled = text.isNotBlank()) { Text("连接") }
        }
    }
}

@Composable
private fun CodeDialog(prompt: CodePrompt, vm: RemoteViewModel) {
    var code by remember(prompt) { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = vm::dismissCodePrompt,
        title = { Text("连接 ${prompt.target.name}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    if (prompt.wrong) "配对码不对，请重新输入。" else "输入 iPad 提词页底部手机图标里显示的 4 位配对码。",
                    color = if (prompt.wrong) Red else Secondary
                )
                OutlinedTextField(
                    value = code,
                    onValueChange = { v -> code = v.filter(Char::isDigit).take(4) },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.headlineMedium.copy(textAlign = TextAlign.Center, letterSpacing = 8.sp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { vm.submitCode(code) }, enabled = code.length == 4) { Text("连接") }
        },
        dismissButton = { TextButton(onClick = vm::dismissCodePrompt) { Text("取消") } },
    )
}

// MARK: 提词状态

@Composable
private fun StatusCard(state: UiState) {
    val s = state.status
    if (s == null) {
        if (state.phase is Phase.Connected) {
            Box(Modifier.fillMaxWidth().heightIn(min = 120.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Secondary)
            }
        }
        return
    }
    Column(
        Modifier.fillMaxWidth().background(Card, RoundedCornerShape(16.dp)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(s.title.ifEmpty { "未命名稿件" }, color = Color.White, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text(
                s.stateText, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier
                    .background((if (s.running) Green else Gray).copy(alpha = 0.3f), CircleShape)
                    .padding(horizontal = 8.dp, vertical = 3.dp)
            )
        }
        LinearProgressIndicator(progress = { s.progress.toFloat() }, color = Orange, trackColor = Gray.copy(alpha = 0.4f),
            modifier = Modifier.fillMaxWidth())
        Row {
            Text("%d:%02d".format(s.elapsed / 60, s.elapsed % 60), color = Secondary, fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            Text("${(s.progress * 100).toInt()}%", color = Secondary, fontSize = 12.sp)
            Spacer(Modifier.weight(1f))
            Text("重读 ${s.rereadCount} 次", color = Secondary, fontSize = 12.sp)
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(Gray.copy(alpha = 0.4f)))
        Text(s.current.ifEmpty { "—" }, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp,
            maxLines = 3, overflow = TextOverflow.Ellipsis)
        if (s.next.isNotEmpty()) {
            Text(s.next, color = Secondary, fontSize = 15.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

// MARK: 按钮

@Composable
private fun Controls(state: UiState, vm: RemoteViewModel) {
    val enabled = state.phase is Phase.Connected
    val s = state.status
    val haptic = LocalHapticFeedback.current
    fun send(c: Command, strong: Boolean = false) {
        haptic.performHapticFeedback(if (strong) HapticFeedbackType.LongPress else HapticFeedbackType.TextHandleMove)
        vm.send(c)
    }
    Column(
        Modifier.alpha(if (enabled) 1f else 0.4f),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        RemoteButton(Red, enabled, Modifier.fillMaxWidth().height(130.dp), { send(Command.RereadSentence, true) }) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.Undo, null, tint = Color.White, modifier = Modifier.size(36.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("重读本句", color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.Black)
                }
                Text("连按逐句后退", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            BigButton("重读本段", Icons.Filled.Replay, Orange, enabled, Modifier.weight(1f)) { send(Command.RereadParagraph, true) }
            BigButton("回到开头", Icons.Filled.SkipPrevious, Gray, enabled, Modifier.weight(1f)) { send(Command.Restart) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            BigButton("上一句", Icons.Filled.KeyboardArrowUp, Gray, enabled, Modifier.weight(1f)) { send(Command.PreviousSentence) }
            val playing = s != null && (s.running || s.countdown != null)
            RemoteButton(Green, enabled, Modifier.weight(1f).height(84.dp), { send(Command.Toggle) }) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "暂停" else "开始",
                    tint = Color.White, modifier = Modifier.size(40.dp))
            }
            BigButton("下一句", Icons.Filled.KeyboardArrowDown, Gray, enabled, Modifier.weight(1f)) { send(Command.NextSentence) }
        }
        if (s?.mode == "auto") {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                BigButton("慢一点", Icons.Filled.FastRewind, Blue, enabled, Modifier.weight(1f)) { send(Command.Slower) }
                Text("${s.autoSpeed}", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center, modifier = Modifier.width(70.dp))
                BigButton("快一点", Icons.Filled.FastForward, Blue, enabled, Modifier.weight(1f)) { send(Command.Faster) }
            }
        }
    }
}

@Composable
private fun BigButton(title: String, icon: ImageVector, color: Color, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    RemoteButton(color, enabled, modifier.height(84.dp), onClick) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(28.dp))
            Spacer(Modifier.height(4.dp))
            Text(title, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
private fun RemoteButton(color: Color, enabled: Boolean, modifier: Modifier, onClick: () -> Unit, content: @Composable () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        modifier
            .scale(if (pressed) 0.97f else 1f)
            .background(color.copy(alpha = if (pressed) 0.55f else 0.85f), RoundedCornerShape(20.dp))
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center
    ) { content() }
}
