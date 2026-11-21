package com.xunrana.lnulibseat

import android.app.ActivityOptions
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/**
 * Android 静音防墓碑冻结保活器（对标 iOS AppDelegate.swift 的 AVAudioPlayer 全零静音流）。
 *
 * 原理：vivo OriginOS 4 (PEM) / 小米 HyperOS (Millet) / OPPO ColorOS (Hans) / 华为 HarmonyOS
 * 即便开启电池优化白名单，仍会在锁屏 10 秒后冻结普通 specialUse 前台服务的 Linux cgroup；
 * 但所有国产 ROM 的冻结器都会检查 AudioFlinger 活跃音频轨，绝不冻结正在播放音频的 UID。
 * 本类在定时守夜期间循环播放纯内存全零 PCM（绝对无声、不申请 AudioFocus、不打断任何音乐/视频、
 * 不弹出锁屏媒体卡片），抢座结束或中止后立即 stop + release。
 */
object SilentAudioKeepAlive {
    private val lock = Any()
    private var audioTrack: AudioTrack? = null
    @Volatile var activeSampleRate: Int = 0
        private set

    fun isActive(): Boolean = synchronized(lock) {
        val t = audioTrack
        t != null && t.state == AudioTrack.STATE_INITIALIZED && t.playState == AudioTrack.PLAYSTATE_PLAYING
    }

    fun start(): Pair<Boolean, String> = synchronized(lock) {
        val existing = audioTrack
        if (existing != null &&
            existing.state == AudioTrack.STATE_INITIALIZED &&
            existing.playState == AudioTrack.PLAYSTATE_PLAYING
        ) {
            return Pair(true, "${activeSampleRate}Hz")
        }
        stopLocked()

        val nativeRate = try {
            AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC)
                .takeIf { it in 8000..48000 } ?: 48000
        } catch (_: Exception) {
            48000
        }
        val candidateRates = linkedSetOf(nativeRate, 44100, 48000, 16000)
        var lastErr = "init_failed"

        for (rate in candidateRates) {
            try {
                // 1 秒 16-bit Mono 全零 PCM（纯内存静态循环，零后台线程开销，0.0000 dB 绝对无声）
                val frameCount = rate
                val silenceBytes = ByteArray(frameCount * 2)
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                val fmt = AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
                val track = AudioTrack.Builder()
                    .setAudioAttributes(attrs)
                    .setAudioFormat(fmt)
                    .setBufferSizeInBytes(silenceBytes.size)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                if (track.state != AudioTrack.STATE_INITIALIZED) {
                    track.release()
                    lastErr = "uninitialized_$rate"
                    continue
                }
                val written = track.write(silenceBytes, 0, silenceBytes.size)
                if (written <= 0) {
                    track.release()
                    lastErr = "write_$written"
                    continue
                }
                val loopRes = track.setLoopPoints(0, frameCount, -1)
                if (loopRes != AudioTrack.SUCCESS) {
                    track.release()
                    lastErr = "loop_$loopRes"
                    continue
                }
                // PCM 采样全为 0（绝对无声）；设非零微小增益避免 OEM 将 0.0 音量轨视作静音可挂起
                track.setVolume(0.01f)
                track.play()
                audioTrack = track
                activeSampleRate = rate
                return Pair(true, "${rate}Hz")
            } catch (exc: Exception) {
                lastErr = exc.message ?: exc.javaClass.simpleName
            }
        }
        return Pair(false, lastErr)
    }

    fun stop() = synchronized(lock) {
        stopLocked()
    }

    private fun stopLocked() {
        val t = audioTrack
        audioTrack = null
        activeSampleRate = 0
        if (t != null) {
            try {
                if (t.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    t.pause()
                }
            } catch (_: Exception) {}
            try {
                t.flush()
            } catch (_: Exception) {}
            try {
                t.stop()
            } catch (_: Exception) {}
            try {
                t.release()
            } catch (_: Exception) {}
        }
    }
}

object RushAlarmStore {
    private const val PREF_NAME = "lnu_rush_alarm_prefs"
    private const val KEY_ARMED = "armed"
    private const val KEY_TRIGGER_MS = "trigger_epoch_ms"
    private const val KEY_FIRE_MS = "fire_epoch_ms"
    private const val KEY_SUMMARY = "summary"
    private const val KEY_PENDING_COLD = "pending_cold_start_rush"
    private const val KEY_FIRED_MS = "fired_epoch_ms"

    const val ALARM_REQUEST_CODE = 630
    const val ALARM_PREP_REQUEST_CODE = 631
    const val ALARM_KEEPALIVE_REQUEST_CODE = 632
    const val ALARM_FIRE_REQUEST_CODE = 633
    const val WAKEUP_NOTIF_ID = 6301
    const val WAKEUP_CHANNEL_ID = "lnu_libseat_rush_wakeup"
    const val EXTRA_FROM_EXACT_ALARM = "from_exact_alarm"
    const val EXTRA_ALARM_STAGE = "alarm_stage"
    const val EXTRA_SUMMARY = "summary"
    const val EXTRA_FIRE_AT_MS = "fire_at_epoch_ms"

    fun saveArmed(
        context: Context,
        triggerAtEpochMs: Long,
        fireAtEpochMs: Long,
        summary: String
    ) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ARMED, true)
            .putLong(KEY_TRIGGER_MS, triggerAtEpochMs)
            .putLong(KEY_FIRE_MS, fireAtEpochMs)
            .putString(KEY_SUMMARY, summary)
            .putBoolean(KEY_PENDING_COLD, false)
            .putLong(KEY_FIRED_MS, 0L)
            .apply()
    }

    fun markColdStartTriggered(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_PENDING_COLD, true)
            .putLong(KEY_FIRED_MS, System.currentTimeMillis())
            .apply()
    }

    fun clearAll(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ARMED, false)
            .putBoolean(KEY_PENDING_COLD, false)
            .putLong(KEY_TRIGGER_MS, 0L)
            .putLong(KEY_FIRE_MS, 0L)
            .putLong(KEY_FIRED_MS, 0L)
            .apply()
    }

    fun readState(context: Context): Map<String, Any> {
        val sp = context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        return hashMapOf<String, Any>(
            "armed" to sp.getBoolean(KEY_ARMED, false),
            "coldAlarmFired" to sp.getBoolean(KEY_PENDING_COLD, false),
            "triggerAtEpochMs" to sp.getLong(KEY_TRIGGER_MS, 0L),
            "fireAtEpochMs" to sp.getLong(KEY_FIRE_MS, 0L),
            "firedEpochMs" to sp.getLong(KEY_FIRED_MS, 0L),
            "summary" to (sp.getString(KEY_SUMMARY, "") ?: "")
        )
    }

    fun consumePendingState(context: Context): Map<String, Any> {
        val state = readState(context)
        val sp = context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val fireMs = sp.getLong(KEY_FIRE_MS, 0L)
        val expired = fireMs > 0L && System.currentTimeMillis() > fireMs + 10 * 60 * 1000L
        val editor = sp.edit().putBoolean(KEY_PENDING_COLD, false)
        if (expired) {
            editor.putBoolean(KEY_ARMED, false)
        }
        editor.apply()
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(WAKEUP_NOTIF_ID)
        return state
    }

    /**
     * 四段式硬件 RTC 闹钟保底链：
     * - 630 (wake)      : prepAt - 20s（如 06:29:25）setAlarmClock 主唤醒
     * - 631 (prep)      : prepAt      （如 06:29:45）setAlarmClock 预热登录解冻
     * - 632 (keepalive) : keepaliveAt （如 06:29:55）setExactAndAllowWhileIdle 保活复校解冻
     * - 633 (fire)      : fireAt - 1s （如 06:29:59）setAlarmClock 准点开抢前 1 秒最高优解冻
     *
     * 彻底消灭 06:29:55 → 06:30:00 的 5 秒空窗（原 10 秒广播宽限期恰好在 06:29:55 过期）。
     * 返回 Triple(是否至少挂起1个闹钟, 主模式说明, 实际挂载闹钟数量)。
     */
    fun scheduleRushAlarmChain(
        context: Context,
        triggerAtEpochMs: Long,
        prepAtEpochMs: Long = 0L,
        keepaliveAtEpochMs: Long = 0L,
        fireAtEpochMs: Long = 0L
    ): Triple<Boolean, String, Int> {
        val nowMs = System.currentTimeMillis()
        val appCtx = context.applicationContext
        val alarmManager = appCtx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val showIntent = Intent(appCtx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val showPending = PendingIntent.getActivity(
            appCtx,
            ALARM_REQUEST_CODE + 10,
            showIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val canExact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            alarmManager.canScheduleExactAlarms()
        } else {
            true
        }

        val fireNudgeMs = if (fireAtEpochMs > 1_000L) fireAtEpochMs - 1_000L else 0L
        // (reqCode, triggerMs, stageName, preferAlarmClock)
        val rawStages = listOf(
            Quad(ALARM_REQUEST_CODE, triggerAtEpochMs, "wake", true),
            Quad(ALARM_PREP_REQUEST_CODE, prepAtEpochMs, "prep", true),
            Quad(ALARM_KEEPALIVE_REQUEST_CODE, keepaliveAtEpochMs, "keepalive", false),
            Quad(ALARM_FIRE_REQUEST_CODE, fireNudgeMs, "fire", true),
        )

        var scheduledCount = 0
        var primaryMode = "trigger_in_past"
        var lastScheduledMs = 0L

        for (stage in rawStages) {
            val tMs = stage.triggerMs
            if (tMs <= nowMs + 500L) {
                continue
            }
            // 与上一闹钟间隔 < 2s 时跳过，避免重复打断（但 fire 阶段始终保留）
            if (stage.stageName != "fire" && lastScheduledMs > 0L && kotlin.math.abs(tMs - lastScheduledMs) < 2_000L) {
                continue
            }
            val alarmIntent = Intent(appCtx, RushAlarmReceiver::class.java).apply {
                putExtra(EXTRA_ALARM_STAGE, stage.stageName)
            }
            val pending = PendingIntent.getBroadcast(
                appCtx,
                stage.reqCode,
                alarmIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val mode = try {
                if (canExact && stage.preferAlarmClock && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    alarmManager.setAlarmClock(
                        AlarmManager.AlarmClockInfo(tMs, showPending),
                        pending
                    )
                    "AlarmClock"
                } else if (canExact && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        tMs,
                        pending
                    )
                    "ExactIdle"
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        tMs,
                        pending
                    )
                    "InexactIdle"
                } else {
                    alarmManager.setExact(AlarmManager.RTC_WAKEUP, tMs, pending)
                    "ExactLegacy"
                }
            } catch (se: SecurityException) {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, tMs, pending)
                        "FallbackInexact"
                    } else {
                        alarmManager.set(AlarmManager.RTC_WAKEUP, tMs, pending)
                        "FallbackLegacy"
                    }
                } catch (_: Exception) {
                    null
                }
            } catch (_: Exception) {
                null
            }
            if (mode != null) {
                if (scheduledCount == 0) {
                    primaryMode = mode
                }
                scheduledCount += 1
                lastScheduledMs = tMs
            }
        }
        return Triple(scheduledCount > 0, primaryMode, scheduledCount)
    }

    private data class Quad(
        val reqCode: Int,
        val triggerMs: Long,
        val stageName: String,
        val preferAlarmClock: Boolean,
    )

    fun cancelRushAlarmClock(context: Context) {
        val appCtx = context.applicationContext
        val alarmManager = appCtx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for (reqCode in intArrayOf(
            ALARM_REQUEST_CODE,
            ALARM_PREP_REQUEST_CODE,
            ALARM_KEEPALIVE_REQUEST_CODE,
            ALARM_FIRE_REQUEST_CODE
        )) {
            val alarmIntent = Intent(appCtx, RushAlarmReceiver::class.java)
            val pending = PendingIntent.getBroadcast(
                appCtx,
                reqCode,
                alarmIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.cancel(pending)
            pending.cancel()
        }
        val nm = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(WAKEUP_NOTIF_ID)
    }

    fun startForegroundGuard(context: Context, summary: String, fireAtEpochMs: Long): Pair<Boolean, String> {
        val appCtx = context.applicationContext
        val serviceIntent = Intent(appCtx, RushForegroundService::class.java).apply {
            putExtra(EXTRA_SUMMARY, summary)
            putExtra(EXTRA_FIRE_AT_MS, fireAtEpochMs)
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appCtx.startForegroundService(serviceIntent)
            } else {
                appCtx.startService(serviceIntent)
            }
            Pair(true, "ok")
        } catch (exc: Exception) {
            Pair(false, exc.message ?: exc.javaClass.simpleName)
        }
    }
}

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.xunrana.lnulibseat/background"
        @Volatile var activeChannel: MethodChannel? = null
        @Volatile var isActivityResumed: Boolean = false
    }

    private var boundChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val armed = (RushAlarmStore.readState(this)["armed"] as? Boolean) == true
        val fromAlarm = intent?.getBooleanExtra(RushAlarmStore.EXTRA_FROM_EXACT_ALARM, false) == true
        if (armed || fromAlarm) {
            allowWakeOverLockScreen()
        }
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed = true
    }

    override fun onPause() {
        isActivityResumed = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        boundChannel = channel
        activeChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundRushService" -> {
                    val triggerAtEpochMs = call.argument<Number>("triggerAtEpochMs")?.toLong() ?: 0L
                    val prepAtEpochMs = call.argument<Number>("prepAtEpochMs")?.toLong()
                        ?: (triggerAtEpochMs + 20_000L)
                    val fireAtEpochMs = call.argument<Number>("fireAtEpochMs")?.toLong()
                        ?: (prepAtEpochMs + 15_000L)
                    val keepaliveAtEpochMs = call.argument<Number>("keepaliveAtEpochMs")?.toLong()
                        ?: (fireAtEpochMs - 5_000L)
                    val summary = call.argument<String>("summary") ?: "06:30 准点抢座守夜中"
                    result.success(
                        startRushServiceAndAlarm(
                            triggerAtEpochMs,
                            prepAtEpochMs,
                            keepaliveAtEpochMs,
                            fireAtEpochMs,
                            summary
                        )
                    )
                }
                "stopForegroundRushService" -> {
                    stopRushServiceAndAlarm()
                    result.success(null)
                }
                "consumePendingAlarmRush" -> {
                    result.success(RushAlarmStore.consumePendingState(this))
                }
                "getKeepAliveStatus" -> {
                    result.success(readKeepAliveStatus())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestBatteryWhitelist()
                    result.success(null)
                }
                "requestExactAlarmPermission" -> {
                    requestExactAlarmSettings()
                    result.success(null)
                }
                "openAppNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                "openAppDetailsSettings" -> {
                    openAppDetailsPage()
                    result.success(null)
                }
                "requestFullScreenIntentPermission" -> {
                    requestFullScreenIntentSettings()
                    result.success(null)
                }
                "decodeImageRgba" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.isEmpty()) {
                        result.success(null)
                    } else {
                        result.success(decodeImageRgbaCpu(bytes))
                    }
                }
                "scheduleCheckinReminder" -> {
                    val alarmId = call.argument<Number>("alarmId")?.toInt() ?: 0
                    val triggerAtEpochMs = call.argument<Number>("triggerAtEpochMs")?.toLong() ?: 0L
                    val title = call.argument<String>("title") ?: "图书馆签到提醒"
                    val body = call.argument<String>("body") ?: "请按时前往图书馆刷卡签到，避免违约。"
                    val urgent = call.argument<Boolean>("urgent") ?: false
                    val ok = scheduleCheckinReminderAlarm(
                        alarmId = alarmId,
                        triggerAtEpochMs = triggerAtEpochMs,
                        title = title,
                        body = body,
                        urgent = urgent
                    )
                    result.success(ok)
                }
                "cancelCheckinReminder" -> {
                    val alarmId = call.argument<Number>("alarmId")?.toInt() ?: 0
                    cancelCheckinReminderAlarm(alarmId)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        handleIncomingIntent(intent)
    }

    override fun onDestroy() {
        if (activeChannel === boundChannel) {
            activeChannel = null
        }
        boundChannel = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        val data: Uri? = intent?.data
        if (data != null && data.scheme == "lnulibseat") {
            activeChannel?.invokeMethod("onDeepLink", data.toString())
        }
        if (intent?.getBooleanExtra(RushAlarmStore.EXTRA_FROM_EXACT_ALARM, false) == true) {
            allowWakeOverLockScreen()
            activeChannel?.invokeMethod("onAlarmFired", "exact_alarm_wake")
        }
    }

    private fun allowWakeOverLockScreen() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
        } catch (_: Exception) {}
    }

    private fun clearWakeOverLockScreen() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            } else {
                @Suppress("DEPRECATION")
                window.clearFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
        } catch (_: Exception) {}
    }

    private fun startRushServiceAndAlarm(
        triggerAtEpochMs: Long,
        prepAtEpochMs: Long,
        keepaliveAtEpochMs: Long,
        fireAtEpochMs: Long,
        summary: String
    ): Map<String, Any> {
        RushAlarmStore.saveArmed(this, triggerAtEpochMs, fireAtEpochMs, summary)
        // 定时守夜期间允许闹钟在锁屏上直接亮屏并唤醒 MainActivity
        allowWakeOverLockScreen()
        // 前台即时激活静音防墓碑音频轨（对标 iOS 静音保活，vivo/小米/OPPO/华为内核均不冻结活跃播放 UID）
        val (audioOk, audioInfo) = SilentAudioKeepAlive.start()
        val (fgsOk, fgsMsg) = RushAlarmStore.startForegroundGuard(this, summary, fireAtEpochMs)
        val (alarmOk, alarmMode, alarmCount) = RushAlarmStore.scheduleRushAlarmChain(
            this,
            triggerAtEpochMs = triggerAtEpochMs,
            prepAtEpochMs = prepAtEpochMs,
            keepaliveAtEpochMs = keepaliveAtEpochMs,
            fireAtEpochMs = fireAtEpochMs
        )
        return hashMapOf<String, Any>(
            "ok" to (fgsOk || alarmOk || audioOk),
            "fgsStarted" to fgsOk,
            "fgsMessage" to fgsMsg,
            "alarmScheduled" to alarmOk,
            "alarmMode" to alarmMode,
            "alarmCount" to alarmCount,
            "silentAudioActive" to audioOk,
            "silentAudioInfo" to audioInfo
        )
    }

    private fun stopRushServiceAndAlarm() {
        RushAlarmStore.clearAll(this)
        SilentAudioKeepAlive.stop()
        clearWakeOverLockScreen()
        stopService(Intent(this, RushForegroundService::class.java))
        RushAlarmStore.cancelRushAlarmClock(this)
    }

    private fun readKeepAliveStatus(): Map<String, Any> {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val ignoringBattery = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pm.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
        val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val canExact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.canScheduleExactAlarms()
        } else {
            true
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notifEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            nm.areNotificationsEnabled()
        } else {
            true
        }
        val canFullScreen = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                nm.canUseFullScreenIntent()
            } catch (_: Exception) {
                true
            }
        } else {
            true
        }
        val state = RushAlarmStore.readState(this)
        return hashMapOf<String, Any>(
            "ignoringBatteryOptimizations" to ignoringBattery,
            "canScheduleExactAlarms" to canExact,
            "notificationsEnabled" to notifEnabled,
            "canUseFullScreenIntent" to canFullScreen,
            "armed" to (state["armed"] as? Boolean ?: false),
            "fireAtEpochMs" to (state["fireAtEpochMs"] as? Long ?: 0L)
        )
    }

    private fun requestBatteryWhitelist() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                } catch (_: Exception) {
                    val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    startActivity(fallback)
                }
            } else {
                // 已在白名单内，跳到电池优化详情页方便核对或复查国产 ROM 自启动项
                try {
                    val detail = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(detail)
                } catch (_: Exception) {}
            }
        }
    }

    private fun requestExactAlarmSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (_: Exception) {
                try {
                    val detail = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(detail)
                } catch (_: Exception) {}
            }
        }
    }

    private fun openNotificationSettings() {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }
            startActivity(intent)
        } catch (_: Exception) {}
    }

    private fun openAppDetailsPage() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        } catch (_: Exception) {}
    }

    private fun requestFullScreenIntentSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
                return
            } catch (_: Exception) {}
        }
        openAppDetailsPage()
    }

    /**
     * 纯 CPU 原生解码 JPEG/PNG（底层同为 Skia + libjpeg-turbo / libpng），
     * 不依赖 Impeller GPU 纹理上传/回读，熄屏/后台 06:30 定时守夜期间同样 100% 稳定。
     */
    private fun decodeImageRgbaCpu(bytes: ByteArray): Map<String, Any>? {
        val opts = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
            inPremultiplied = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
            }
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
        return try {
            val width = bitmap.width
            val height = bitmap.height
            if (width <= 0 || height <= 0) {
                null
            } else {
                val rgba = ByteArray(width * height * 4)
                bitmap.copyPixelsToBuffer(ByteBuffer.wrap(rgba))
                hashMapOf<String, Any>(
                    "width" to width,
                    "height" to height,
                    "rgba" to rgba
                )
            }
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * 注册 Android 系统级签到防违约闹钟（App 划掉/息屏待机也能准时弹出高优通知）。
     */
    private fun scheduleCheckinReminderAlarm(
        alarmId: Int,
        triggerAtEpochMs: Long,
        title: String,
        body: String,
        urgent: Boolean
    ): Boolean {
        if (alarmId <= 0 || triggerAtEpochMs <= System.currentTimeMillis()) {
            return false
        }
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, CheckinReminderReceiver::class.java).apply {
            putExtra(CheckinReminderReceiver.EXTRA_ALARM_ID, alarmId)
            putExtra(CheckinReminderReceiver.EXTRA_TITLE, title)
            putExtra(CheckinReminderReceiver.EXTRA_BODY, body)
            putExtra(CheckinReminderReceiver.EXTRA_URGENT, urgent)
        }
        val pending = PendingIntent.getBroadcast(
            this,
            alarmId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val canExact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            alarmManager.canScheduleExactAlarms()
        } else {
            true
        }
        return try {
            if (canExact && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtEpochMs,
                    pending
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtEpochMs,
                    pending
                )
            } else {
                alarmManager.setExact(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtEpochMs,
                    pending
                )
            }
            true
        } catch (_: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtEpochMs,
                    pending
                )
            } else {
                alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAtEpochMs, pending)
            }
            true
        }
    }

    private fun cancelCheckinReminderAlarm(alarmId: Int) {
        if (alarmId <= 0) {
            return
        }
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, CheckinReminderReceiver::class.java)
        val pending = PendingIntent.getBroadcast(
            this,
            alarmId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        alarmManager.cancel(pending)
        pending.cancel()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(alarmId)
    }
}

class RushForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val persisted = RushAlarmStore.readState(this)
        val summary = intent?.getStringExtra(RushAlarmStore.EXTRA_SUMMARY)
            ?.takeIf { it.isNotBlank() }
            ?: (persisted["summary"] as? String)?.takeIf { it.isNotBlank() }
            ?: "06:30 准点抢座守夜中"
        val fireAtEpochMs = intent?.getLongExtra(RushAlarmStore.EXTRA_FIRE_AT_MS, 0L)
            ?.takeIf { it > 0L }
            ?: (persisted["fireAtEpochMs"] as? Long ?: 0L)

        val channelId = "lnu_libseat_foreground_guard_v2"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "LNU-LibSeat 隔夜守夜服务",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "保持 06:30 准点抢座进程与网络连接活跃"
                setSound(null, null)
                enableVibration(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        val openIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentPending = PendingIntent.getActivity(
            this,
            6302,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("🎯 LNU-LibSeat 隔夜守夜已激活")
            .setContentText(summary)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentIntent(contentPending)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                startForeground(
                    6300,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } catch (_: Exception) {
                startForeground(6300, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(6300, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } catch (_: Exception) {
                startForeground(6300, notification)
            }
        } else {
            startForeground(6300, notification)
        }

        // 确保静音防墓碑音频轨在服务运行期内始终活跃（冷启动复活时也可自启）
        SilentAudioKeepAlive.start()

        // 动态计算 WakeLock 时长：覆盖到目标开抢时间后 20 分钟（最长 26 小时），彻底解决晚上提前开启导致 10h 过期问题
        val nowMs = System.currentTimeMillis()
        val dynamicMs = if (fireAtEpochMs > nowMs) {
            ((fireAtEpochMs - nowMs) + 20 * 60 * 1000L)
                .coerceIn(10 * 60 * 1000L, 26 * 60 * 60 * 1000L)
        } else {
            30 * 60 * 1000L
        }

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "LNU-LibSeat::RushWakeLock"
            ).apply {
                setReferenceCounted(false)
                acquire(dynamicMs)
            }
        } catch (_: Exception) {}

        // 申请 WifiLock，防止手机息屏数小时后 Wi-Fi 进入深度休眠导致 06:29:45 登录超时
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wm != null && (wifiLock == null || wifiLock?.isHeld != true)) {
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "LNU-LibSeat::RushWifiLock").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {}

        return START_STICKY
    }

    override fun onDestroy() {
        SilentAudioKeepAlive.stop()
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        wakeLock = null
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {}
        wifiLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

class RushAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val state = RushAlarmStore.readState(context)
        val armed = state["armed"] as? Boolean ?: false
        if (!armed) {
            return
        }

        val summary = (state["summary"] as? String)?.takeIf { it.isNotBlank() }
            ?: "准点抢座闹钟已触发，正在执行"
        val fireAtEpochMs = state["fireAtEpochMs"] as? Long ?: 0L
        val stage = intent?.getStringExtra(RushAlarmStore.EXTRA_ALARM_STAGE) ?: "wake"

        // 1. 立即锁定 CPU 3 分钟 + 启动静音防冻结音频轨 + 恢复前台守夜服务与 WifiLock
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        try {
            val wl = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "LNU-LibSeat::ExactAlarmWakeLock"
            )
            wl.setReferenceCounted(false)
            wl.acquire(180 * 1000L)
        } catch (_: Exception) {}

        SilentAudioKeepAlive.start()
        RushAlarmStore.startForegroundGuard(context, summary, fireAtEpochMs)

        // 2. 关键修复（针对 vivo OriginOS / 小米 / OPPO Android 14 墓碑冻结机制）：
        //    当手机锁屏或 App 在后台时，进程可能处于「未死但被 Linux cgroup 冻结」状态，此时 activeChannel 非空但 Dart 引擎已被暂停！
        //    因此只要屏幕处于熄灭或界面不在前台，无论进程是被杀还是被冻结，都必须主动拉起 MainActivity + fullScreenIntent 解冻！
        val channel = MainActivity.activeChannel
        val isScreenOn = try {
            pm.isInteractive
        } catch (_: Exception) {
            false
        }
        val needSurfaceWakeup = channel == null || !MainActivity.isActivityResumed || !isScreenOn

        // 息屏态顺手点亮屏幕 15 秒，确保 WindowManager 将 MainActivity 拉到锁屏最前台 (OOM_ADJ=0)
        if (!isScreenOn) {
            try {
                @Suppress("DEPRECATION")
                val screenWl = pm.newWakeLock(
                    PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "LNU-LibSeat::AlarmScreenWakeLock"
                )
                screenWl.setReferenceCounted(false)
                screenWl.acquire(15 * 1000L)
            } catch (_: Exception) {}
        }

        if (channel != null) {
            channel.invokeMethod("onAlarmFired", "exact_alarm_$stage")
        } else {
            RushAlarmStore.markColdStartTriggered(context)
        }

        if (needSurfaceWakeup) {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(RushAlarmStore.EXTRA_FROM_EXACT_ALARM, true)
            }
            val fullPending = PendingIntent.getActivity(
                context,
                RushAlarmStore.WAKEUP_NOTIF_ID,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            // Android 14+ BAL 合规拉起：优先通过允许后台启动的 PendingIntent 拉起 MainActivity，失败回退 startActivity
            var launched = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                try {
                    @Suppress("DEPRECATION")
                    val opts = ActivityOptions.makeBasic()
                        .setPendingIntentBackgroundActivityStartMode(
                            ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                        )
                        .toBundle()
                    fullPending.send(context, 0, null, null, null, null, opts)
                    launched = true
                } catch (_: Exception) {}
            }
            if (!launched) {
                try {
                    context.startActivity(launchIntent)
                } catch (_: Exception) {}
            }

            // Android 14/15/16 锁屏穿透兜底：同步发 fullScreenIntent 高优唤醒通知，强制解冻前台 Activity 与 Dart Isolate
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val ch = NotificationChannel(
                        RushAlarmStore.WAKEUP_CHANNEL_ID,
                        "LNU-LibSeat 准点闹钟唤醒",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "06:30 准点抢座前自动唤醒并解冻应用执行"
                    }
                    nm.createNotificationChannel(ch)
                }
                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(context, RushAlarmStore.WAKEUP_CHANNEL_ID)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(context)
                }
                val notif = builder
                    .setContentTitle("⏰ 准点约座闹钟已唤醒")
                    .setContentText(summary)
                    .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                    .setCategory(Notification.CATEGORY_ALARM)
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    .setAutoCancel(true)
                    .setContentIntent(fullPending)
                    .setFullScreenIntent(fullPending, true)
                    .build()
                nm.notify(RushAlarmStore.WAKEUP_NOTIF_ID, notif)
            } catch (_: Exception) {}
        }
    }
}

class RushBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val state = RushAlarmStore.readState(context)
        val armed = state["armed"] as? Boolean ?: false
        if (!armed) {
            return
        }
        val triggerMs = state["triggerAtEpochMs"] as? Long ?: 0L
        val fireMs = state["fireAtEpochMs"] as? Long ?: 0L
        val nowMs = System.currentTimeMillis()
        if (fireMs <= nowMs) {
            RushAlarmStore.clearAll(context)
            return
        }
        val effectiveTrigger = if (triggerMs > nowMs) triggerMs else nowMs + 5_000L
        val prepMs = (fireMs - 15_000L).coerceAtLeast(0L)
        val keepaliveMs = (fireMs - 5_000L).coerceAtLeast(0L)
        RushAlarmStore.scheduleRushAlarmChain(
            context,
            triggerAtEpochMs = effectiveTrigger,
            prepAtEpochMs = prepMs,
            keepaliveAtEpochMs = keepaliveMs,
            fireAtEpochMs = fireMs
        )
    }
}

class CheckinReminderReceiver : BroadcastReceiver() {
    companion object {
        const val CHANNEL_ID = "lnu_libseat_checkin_reminder"
        const val EXTRA_ALARM_ID = "alarm_id"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_URGENT = "urgent"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val alarmId = intent?.getIntExtra(EXTRA_ALARM_ID, 20000001) ?: 20000001
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "图书馆签到提醒"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "请按时前往图书馆刷卡签到，避免违约。"
        val urgent = intent?.getBooleanExtra(EXTRA_URGENT, false) ?: false

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "图书馆签到防违约提醒",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "预约开始前 15 分钟与签到截止前 10 分钟准时提醒刷卡"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 350, 200, 350)
            }
            nm.createNotificationChannel(channel)
        }

        val launchIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        val contentIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                context,
                alarmId,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            null
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }

        builder
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_REMINDER)

        if (contentIntent != null) {
            builder.setContentIntent(contentIntent)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(
                if (urgent) Notification.PRIORITY_MAX else Notification.PRIORITY_HIGH
            )
            @Suppress("DEPRECATION")
            builder.setDefaults(Notification.DEFAULT_ALL)
        }

        nm.notify(alarmId, builder.build())
    }
}
