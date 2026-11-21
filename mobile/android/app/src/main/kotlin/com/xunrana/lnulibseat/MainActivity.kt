package com.xunrana.lnulibseat

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.xunrana.lnulibseat/background"
        var activeChannel: MethodChannel? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        activeChannel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundRushService" -> {
                    val triggerAtEpochMs = call.argument<Number>("triggerAtEpochMs")?.toLong() ?: 0L
                    val summary = call.argument<String>("summary") ?: "06:30 准点抢座守夜中"
                    startRushServiceAndAlarm(triggerAtEpochMs, summary)
                    result.success(true)
                }
                "stopForegroundRushService" -> {
                    stopRushServiceAndAlarm()
                    result.success(null)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestBatteryWhitelist()
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        val data: Uri? = intent?.data
        if (data != null && data.scheme == "lnulibseat") {
            activeChannel?.invokeMethod("onDeepLink", data.toString())
        }
        if (intent?.getBooleanExtra("from_exact_alarm", false) == true) {
            activeChannel?.invokeMethod("onAlarmFired", "exact_alarm_062940")
        }
    }

    private fun startRushServiceAndAlarm(triggerAtEpochMs: Long, summary: String) {
        val serviceIntent = Intent(this, RushForegroundService::class.java).apply {
            putExtra("summary", summary)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        if (triggerAtEpochMs > System.currentTimeMillis()) {
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val alarmIntent = Intent(this, RushAlarmReceiver::class.java)
            val pending = PendingIntent.getBroadcast(
                this,
                630,
                alarmIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtEpochMs,
                    pending
                )
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAtEpochMs, pending)
            }
        }
    }

    private fun stopRushServiceAndAlarm() {
        stopService(Intent(this, RushForegroundService::class.java))
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val alarmIntent = Intent(this, RushAlarmReceiver::class.java)
        val pending = PendingIntent.getBroadcast(
            this,
            630,
            alarmIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        alarmManager.cancel(pending)
    }

    private fun requestBatteryWhitelist() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            }
        }
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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val summary = intent?.getStringExtra("summary") ?: "06:30 准点抢座守夜中"
        val channelId = "lnu_libseat_foreground_guard"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "LNU-LibSeat 06:30 定时守夜服务",
                NotificationManager.IMPORTANCE_LOW
            )
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setContentTitle("🎯 LNU-LibSeat 定时守夜已激活")
                .setContentText(summary)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("🎯 LNU-LibSeat 定时守夜已激活")
                .setContentText(summary)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setOngoing(true)
                .build()
        }

        startForeground(6300, notification)

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (wakeLock == null) {
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "LNU-LibSeat::RushWakeLock"
            ).apply {
                acquire(10 * 60 * 60 * 1000L) // 最长守护 10 小时至次日早晨
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

class RushAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wl = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "LNU-LibSeat::ExactAlarmWakeLock"
        )
        wl.acquire(120 * 1000L) // 保持 CPU 唤醒 2 分钟完成 06:29:45 登录与 06:30:00 秒抢
        MainActivity.activeChannel?.invokeMethod("onAlarmFired", "exact_alarm_062940")
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
