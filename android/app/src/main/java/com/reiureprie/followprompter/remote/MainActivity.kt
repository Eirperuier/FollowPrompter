package com.reiureprie.followprompter.remote

import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    private val vm: RemoteViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 锁屏会断开连接，录制时保持亮屏
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContent { RemoteScreen(vm) }
    }

    override fun onStart() {
        super.onStart()
        vm.resume()
    }

    override fun onStop() {
        super.onStop()
        vm.pause()
    }

    /** 音量键当翻页笔用：下 = 重读本句，上 = 开始 / 暂停（仅在已连接时接管） */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val key = event.keyCode
        if (vm.state.value.volumeKeys && vm.isConnected &&
            (key == KeyEvent.KEYCODE_VOLUME_DOWN || key == KeyEvent.KEYCODE_VOLUME_UP)
        ) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                vm.send(if (key == KeyEvent.KEYCODE_VOLUME_DOWN) Command.RereadSentence else Command.Toggle)
                window.decorView.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
