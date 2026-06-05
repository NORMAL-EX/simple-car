package com.videostream.video_stream

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.videostream/wakelock"
    private val DUAL_CAM_CHANNEL = "com.videostream/dualcam"
    private var wakeLock: PowerManager.WakeLock? = null
    private var isKeepingScreenOn = false
    private var originalScreenTimeout: Int = -1
    private var keepScreenHandler: Handler? = null
    private var keepScreenRunnable: Runnable? = null
    private var dualCameraService: DualCameraService? = null
    private var dualCamMethodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 双摄像头服务
        dualCamMethodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DUAL_CAM_CHANNEL)
        dualCamMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val useFront = call.argument<Boolean>("useFront") ?: true
                    startDualCamera(useFront)
                    result.success(true)
                }
                "stop" -> {
                    dualCameraService?.stop()
                    dualCameraService = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> { enableKeepScreenOn(); result.success(true) }
                "disable" -> { disableKeepScreenOn(); result.success(true) }
                "requestPermissions" -> { requestAllPermissions(); result.success(true) }
                "openDisplaySettings" -> { openDisplaySettings(); result.success(true) }
                "checkStatus" -> { result.success(checkStatus()) }
                else -> result.notImplemented()
            }
        }
        restoreTimeoutIfNeeded()
    }

    // ========== 诊断 ==========

    private fun checkStatus(): Map<String, Any> {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val canWrite = Settings.System.canWrite(this)
        val currentTimeout = try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_OFF_TIMEOUT)
        } catch (_: Exception) { -1 }
        val batteryOptIgnored = pm.isIgnoringBatteryOptimizations(packageName)
        val hasNotifPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else true
        val windowFlag = (window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0
        val wakeLockHeld = wakeLock?.isHeld == true

        return mapOf(
            "canWriteSettings" to canWrite,
            "currentTimeoutMs" to currentTimeout,
            "batteryOptIgnored" to batteryOptIgnored,
            "notificationPermission" to hasNotifPermission,
            "windowFlagSet" to windowFlag,
            "wakeLockHeld" to wakeLockHeld,
            "serviceRunning" to isKeepingScreenOn
        )
    }

    // ========== 权限 ==========

    private fun requestAllPermissions() {
        // 1. 通知权限
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
                return
            }
        }
        // 2. 电池优化白名单
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                })
            }
        } catch (_: Exception) {}
        // 3. 修改系统设置（延迟，避免盖住电池弹窗）
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                if (!Settings.System.canWrite(this)) {
                    startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    })
                }
            } catch (_: Exception) {}
        }, 1500)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001) { requestAllPermissions() }
    }

    private fun openDisplaySettings() {
        try {
            startActivity(Intent(Settings.ACTION_DISPLAY_SETTINGS))
        } catch (_: Exception) {
            try { startActivity(Intent(android.provider.Settings.ACTION_SETTINGS)) } catch (_: Exception) {}
        }
    }

    // ========== 系统屏幕超时 ==========

    private fun setSystemScreenTimeout(timeoutMs: Int): Boolean {
        try {
            if (Settings.System.canWrite(this)) {
                if (originalScreenTimeout < 0) {
                    originalScreenTimeout = Settings.System.getInt(
                        contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, 30000
                    )
                    getSharedPreferences("wakelock", MODE_PRIVATE).edit()
                        .putInt("original_timeout", originalScreenTimeout)
                        .putBoolean("timeout_modified", true).apply()
                }
                Settings.System.putInt(contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, timeoutMs)
                return true
            }
        } catch (_: Exception) {}
        return false
    }

    private fun restoreSystemScreenTimeout() {
        try {
            if (Settings.System.canWrite(this) && originalScreenTimeout > 0) {
                Settings.System.putInt(contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, originalScreenTimeout)
            }
            getSharedPreferences("wakelock", MODE_PRIVATE).edit()
                .putBoolean("timeout_modified", false).apply()
            originalScreenTimeout = -1
        } catch (_: Exception) {}
    }

    private fun restoreTimeoutIfNeeded() {
        try {
            val prefs = getSharedPreferences("wakelock", MODE_PRIVATE)
            if (prefs.getBoolean("timeout_modified", false)) {
                val saved = prefs.getInt("original_timeout", 30000)
                if (saved > 0 && Settings.System.canWrite(this)) {
                    Settings.System.putInt(contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, saved)
                }
                prefs.edit().putBoolean("timeout_modified", false).apply()
            }
        } catch (_: Exception) {}
    }

    // ========== 总控 ==========

    private fun enableKeepScreenOn() {
        isKeepingScreenOn = true

        // 前台服务
        try {
            val serviceIntent = Intent(this, KeepScreenService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (e: Exception) { e.printStackTrace() }

        // 系统屏幕超时改最大
        setSystemScreenTimeout(Int.MAX_VALUE)

        // Android Window FLAG（在标准Android上有效，鸿蒙上可能无效但不妨一试）
        runOnUiThread {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        // WakeLock
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                @Suppress("DEPRECATION")
                wakeLock = pm.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "videostream:screenon"
                )
            }
            if (wakeLock?.isHeld != true) wakeLock?.acquire()
        } catch (_: Exception) {}

        // 定时重设
        startPeriodicKeepScreen()
    }

    private fun disableKeepScreenOn() {
        isKeepingScreenOn = false
        stopPeriodicKeepScreen()
        try { stopService(Intent(this, KeepScreenService::class.java)) } catch (_: Exception) {}
        restoreSystemScreenTimeout()
        runOnUiThread { window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
    }

    private fun startPeriodicKeepScreen() {
        stopPeriodicKeepScreen()
        keepScreenHandler = Handler(Looper.getMainLooper())
        keepScreenRunnable = object : Runnable {
            override fun run() {
                if (!isKeepingScreenOn) return
                setSystemScreenTimeout(Int.MAX_VALUE)
                runOnUiThread { window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
                try { if (wakeLock?.isHeld != true) wakeLock?.acquire() } catch (_: Exception) {}
                keepScreenHandler?.postDelayed(this, 30_000)
            }
        }
        keepScreenHandler?.postDelayed(keepScreenRunnable!!, 30_000)
    }

    private fun stopPeriodicKeepScreen() {
        keepScreenRunnable?.let { keepScreenHandler?.removeCallbacks(it) }
        keepScreenHandler = null; keepScreenRunnable = null
    }

    override fun onDestroy() {
        dualCameraService?.stop()
        disableKeepScreenOn(); wakeLock = null; super.onDestroy()
    }

    private fun startDualCamera(useFront: Boolean) {
        dualCameraService?.stop()
        dualCameraService = DualCameraService(this)
        dualCameraService?.onFrameCallback = { jpegData ->
            runOnUiThread {
                dualCamMethodChannel?.invokeMethod("onFrame", jpegData)
            }
        }
        dualCameraService?.onCameraError = {
            runOnUiThread {
                dualCamMethodChannel?.invokeMethod("onError", null)
            }
        }
        dualCameraService?.start(useFront)
    }
}
