package com.example.pomodoro

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

class FocusGuardService : Service() {

    companion object {
        const val TAG = "FocusGuard"
        const val ACTION_START_OR_UPDATE = "com.example.pomodoro.action.START_OR_UPDATE_GUARD"
        const val ACTION_STOP = "com.example.pomodoro.action.STOP_GUARD"

        const val EXTRA_REMAINING_SECONDS = "remainingSeconds"
        const val EXTRA_DND_ENABLED = "dndEnabled"
        const val EXTRA_APP_LOCK_ENABLED = "appLockEnabled"
        const val EXTRA_BLACKLISTED_PACKAGES = "blacklistedPackages"
        const val EXTRA_TASK_TITLE = "taskTitle"

        private const val CHANNEL_ID = "focus_guard_channel"
        private const val NOTIFICATION_ID = 8001
        private const val POLL_INTERVAL_MS = 500L
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var notificationManager: NotificationManager
    private lateinit var windowManager: WindowManager
    private lateinit var usageStatsManager: UsageStatsManager

    private var savedInterruptionFilter: Int? = null
    private var dndEnabled: Boolean = false
    private var appLockEnabled: Boolean = false
    private var blacklistedPackages: Set<String> = emptySet()
    private var taskTitle: String? = null
    private var safetyDeadlineElapsedMs: Long = 0L

    private var lastUsageQueryTimeMs: Long = 0L
    private var lastProcessedEventTimeMs: Long = 0L
    private var lastForegroundPackage: String? = null
    private var suppressOverlayUntilElapsedMs: Long = 0L
    private var overlayView: View? = null
    private var overlayBlockedPackage: String? = null
    private var monitorActive = false

    private val safetyValveRunnable = Runnable {
        Log.w(TAG, "Native safety valve expired; releasing DND and overlay")
        releaseAndStop()
    }

    private val monitorRunnable = object : Runnable {
        override fun run() {
            if (!monitorActive) return
            val nowElapsed = SystemClock.elapsedRealtime()
            if (safetyDeadlineElapsedMs > 0L && nowElapsed >= safetyDeadlineElapsedMs) {
                Log.w(TAG, "Native safety valve deadline reached during poll; releasing protections")
                releaseAndStop()
                return
            }

            if (appLockEnabled && blacklistedPackages.isNotEmpty()) {
                checkForegroundBlacklist(nowElapsed)
            } else if (overlayView != null) {
                removeOverlay()
            }

            if (monitorActive) {
                handler.postDelayed(this, POLL_INTERVAL_MS)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            Log.d(TAG, "Received ACTION_STOP; releasing protections")
            releaseAndStop()
            return START_NOT_STICKY
        }

        val remainingSec = intent?.getIntExtra(EXTRA_REMAINING_SECONDS, 60)?.coerceAtLeast(1) ?: 60
        dndEnabled = intent?.getBooleanExtra(EXTRA_DND_ENABLED, false) ?: false
        appLockEnabled = intent?.getBooleanExtra(EXTRA_APP_LOCK_ENABLED, false) ?: false
        val packages = intent?.getStringArrayListExtra(EXTRA_BLACKLISTED_PACKAGES) ?: arrayListOf()
        blacklistedPackages = packages.toSet()
        taskTitle = intent?.getStringExtra(EXTRA_TASK_TITLE)

        val notification = buildNotification(remainingSec)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val safetyWindowMs = (remainingSec + 2) * 1000L
        safetyDeadlineElapsedMs = SystemClock.elapsedRealtime() + safetyWindowMs
        handler.removeCallbacks(safetyValveRunnable)
        handler.postDelayed(safetyValveRunnable, safetyWindowMs)

        applyDndSetting()

        val nowMs = System.currentTimeMillis()
        if (lastUsageQueryTimeMs == 0L) {
            lastUsageQueryTimeMs = nowMs - 30_000L
        }

        if (!monitorActive) {
            monitorActive = true
            handler.removeCallbacks(monitorRunnable)
            handler.post(monitorRunnable)
        }

        Log.d(
            TAG,
            "Guard active: rem=${remainingSec}s (+2s safety), dnd=$dndEnabled, lock=$appLockEnabled, blacklist=${blacklistedPackages.size}"
        )
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseAllProtections()
        super.onDestroy()
    }

    private fun ensureNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Smart Pomodoro 專注守護",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "於專注倒數期間維持勿擾與應用程式鎖定保護"
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(remainingSeconds: Int): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            null
        }

        val minutes = remainingSeconds / 60
        val seconds = remainingSeconds % 60
        val timeText = String.format("%02d:%02d", minutes, seconds)
        val subtitle = if (!taskTitle.isNullOrBlank()) {
            "$taskTitle · 剩餘約 $timeText"
        } else {
            "專注防護啟用中 · 剩餘約 $timeText"
        }

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Smart Pomodoro 專注守護中")
            .setContentText(subtitle)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setOngoing(true)
            .apply {
                if (pendingIntent != null) {
                    setContentIntent(pendingIntent)
                }
            }
            .build()
    }

    private fun applyDndSetting() {
        if (!notificationManager.isNotificationPolicyAccessGranted) {
            return
        }
        if (dndEnabled) {
            if (savedInterruptionFilter == null) {
                savedInterruptionFilter = notificationManager.currentInterruptionFilter
            }
            if (notificationManager.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_PRIORITY) {
                notificationManager.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
                Log.d(TAG, "DND enabled (saved filter=$savedInterruptionFilter)")
            }
        } else {
            restoreDndIfSaved()
        }
    }

    private fun restoreDndIfSaved() {
        val prior = savedInterruptionFilter ?: return
        savedInterruptionFilter = null
        if (notificationManager.isNotificationPolicyAccessGranted) {
            try {
                notificationManager.setInterruptionFilter(prior)
                Log.d(TAG, "DND restored to filter=$prior")
            } catch (e: SecurityException) {
                Log.w(TAG, "Failed restoring DND filter: ${e.message}")
            }
        }
    }

    private fun checkForegroundBlacklist(nowElapsed: Long) {
        val appOpsGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
            appOps.unsafeCheckOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            ) == android.app.AppOpsManager.MODE_ALLOWED
        } else {
            @Suppress("DEPRECATION")
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            ) == android.app.AppOpsManager.MODE_ALLOWED
        }
        if (!appOpsGranted) return

        val nowMs = System.currentTimeMillis()
        val queryStart = (lastUsageQueryTimeMs - 1_000L).coerceAtLeast(0L)
        val events = usageStatsManager.queryEvents(queryStart, nowMs)
        val event = UsageEvents.Event()
        var latestResumedPkg: String? = null
        var latestResumedTs = lastProcessedEventTimeMs

        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            // Event type 1 corresponds to MOVE_TO_FOREGROUND / ACTIVITY_RESUMED.
            if (event.eventType == 1 && event.timeStamp > latestResumedTs && !event.packageName.isNullOrEmpty()) {
                latestResumedTs = event.timeStamp
                latestResumedPkg = event.packageName
            }
        }
        lastUsageQueryTimeMs = nowMs

        if (latestResumedPkg != null) {
            lastProcessedEventTimeMs = latestResumedTs
            lastForegroundPackage = latestResumedPkg
        }

        val currentFg = lastForegroundPackage
        if (currentFg == packageName) {
            if (overlayView != null) {
                removeOverlay()
            }
            return
        }

        if (nowElapsed < suppressOverlayUntilElapsedMs) {
            return
        }

        if (currentFg != null && blacklistedPackages.contains(currentFg)) {
            if (Settings.canDrawOverlays(this)) {
                if (overlayView == null || overlayBlockedPackage != currentFg) {
                    showOverlay(currentFg)
                }
            } else {
                Log.w(TAG, "Cannot draw overlay for $currentFg; SYSTEM_ALERT_WINDOW missing")
            }
        } else if (overlayView != null) {
            removeOverlay()
        }
    }

    private fun showOverlay(blockedPackage: String) {
        removeOverlay()

        val blockedLabel = resolveAppLabel(blockedPackage)
        val density = resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#F6F5F2"))
            setPadding(dp(28), dp(40), dp(28), dp(40))
            isFocusableInTouchMode = true
        }

        val badge = TextView(this).apply {
            text = "專注鎖定保護中"
            contentDescription = "專注鎖定保護中"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(Color.parseColor("#C84B31"))
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(14), dp(6), dp(14), dp(6))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#FCEAE6"))
                cornerRadius = dp(999).toFloat()
                setStroke(dp(1), Color.parseColor("#C84B31"))
            }
        }

        val titleView = TextView(this).apply {
            text = "專注進行中，暫停使用此應用程式"
            contentDescription = "專注進行中，暫停使用此應用程式"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTextColor(Color.parseColor("#18181B"))
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(0, dp(20), 0, dp(10))
        }

        val subtitleView = TextView(this).apply {
            text = "已封鎖：$blockedLabel ($blockedPackage)"
            contentDescription = "已封鎖：$blockedLabel"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.parseColor("#71717A"))
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(28))
        }

        val returnButton = Button(this).apply {
            text = "返回 Smart Pomodoro"
            contentDescription = "返回 Smart Pomodoro"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            setPadding(dp(24), dp(14), dp(24), dp(14))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#18181B"))
                cornerRadius = dp(12).toFloat()
            }
            setOnClickListener {
                Log.d(TAG, "Overlay return button tapped")
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                if (launchIntent != null) {
                    launchIntent.addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )
                    startActivity(launchIntent)
                }
                lastForegroundPackage = packageName
                suppressOverlayUntilElapsedMs = SystemClock.elapsedRealtime() + 1_200L
                removeOverlay()
            }
        }

        root.addView(
            badge,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )
        root.addView(
            titleView,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )
        root.addView(
            subtitleView,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )
        root.addView(
            returnButton,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        )

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.CENTER
        }

        try {
            windowManager.addView(root, params)
            overlayView = root
            overlayBlockedPackage = blockedPackage
            Log.d(TAG, "Displayed fullscreen overlay blocking $blockedPackage")
        } catch (e: Exception) {
            Log.e(TAG, "Failed adding FocusGuard overlay: ${e.message}")
        }
    }

    private fun removeOverlay() {
        val current = overlayView ?: return
        overlayView = null
        overlayBlockedPackage = null
        try {
            windowManager.removeView(current)
            Log.d(TAG, "Removed fullscreen overlay")
        } catch (e: Exception) {
            Log.w(TAG, "Error removing overlay: ${e.message}")
        }
    }

    private fun resolveAppLabel(pkg: String): String {
        return try {
            val info = packageManager.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
            packageManager.getApplicationLabel(info).toString()
        } catch (_: Throwable) {
            try {
                @Suppress("DEPRECATION")
                val info = packageManager.getApplicationInfo(pkg, 0)
                packageManager.getApplicationLabel(info).toString()
            } catch (_: Throwable) {
                pkg
            }
        }
    }

    private fun releaseAllProtections() {
        monitorActive = false
        handler.removeCallbacks(monitorRunnable)
        handler.removeCallbacks(safetyValveRunnable)
        safetyDeadlineElapsedMs = 0L
        removeOverlay()
        restoreDndIfSaved()
    }

    private fun releaseAndStop() {
        releaseAllProtections()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
}
