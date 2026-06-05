package com.videostream.video_stream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.IBinder
import android.os.PowerManager

/**
 * 前台媒体播放服务
 *
 * 通过 Foreground Service (mediaPlayback类型) + MediaSession (PLAYING状态)
 * 向系统声明"当前有视频在播放"。
 *
 * 鸿蒙系统会检测 MediaSession 的活跃状态来判断是否为合法的媒体播放场景，
 * 从而不会覆盖应用的屏幕常亮设置。
 * 这是 Netflix/YouTube 等视频应用使用的标准机制。
 */
class KeepScreenService : Service() {
    private var mediaSession: MediaSession? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    private var audioTrack: android.media.AudioTrack? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("视频图传")
            .setContentText("视频传输中，保持屏幕常亮")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .build()

        // 以 mediaPlayback 类型启动前台服务
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            startForeground(NOTIFICATION_ID, notification)
        }

        // 创建 MediaSession
        mediaSession = MediaSession(this, "VideoStream").apply {
            setPlaybackState(
                PlaybackState.Builder()
                    .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                    .setActions(
                        PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE
                    )
                    .build()
            )
            isActive = true
        }

        // 核心修复：播放静音音频，防止系统杀后台
        startSilentAudio()

        // CPU 保持唤醒
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "videostream:service")
        wakeLock?.acquire()

        return START_STICKY
    }

    private fun startSilentAudio() {
        if (audioTrack != null) return

        try {
            val sampleRate = 44100
            val encoding = android.media.AudioFormat.ENCODING_PCM_16BIT
            val channelConfig = android.media.AudioFormat.CHANNEL_OUT_MONO
            val bufferSize = android.media.AudioTrack.getMinBufferSize(sampleRate, channelConfig, encoding)

            audioTrack = android.media.AudioTrack(
                android.media.AudioManager.STREAM_MUSIC,
                sampleRate,
                channelConfig,
                encoding,
                bufferSize,
                android.media.AudioTrack.MODE_STREAM
            )

            val silence = ByteArray(bufferSize)
            audioTrack?.play()
            
            // 循环写入静音数据 (在一个单独线程中，避免阻塞主线程)
            Thread {
                try {
                    while (mediaSession?.isActive == true && audioTrack != null) {
                        // 写入数据是阻塞操作，能控制循环速度
                        audioTrack?.write(silence, 0, silence.size)
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }.start()

        } catch (e: Exception) {
            e.printStackTrace()
            audioTrack = null
        }
    }

    override fun onDestroy() {
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
        
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null

        try { wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "视频图传",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "视频传输运行中"
            setShowBadge(false)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "video_stream_keep_screen"
        const val NOTIFICATION_ID = 9001
    }
}
