package com.example.pomodoro

import android.Manifest
import android.app.AppOpsManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class FocusGuardChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "com.example.pomodoro/focus_guard"
        private const val TAG = "FocusGuard"
    }

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermissions" -> result.success(checkPermissions())
            "openPermissionSettings" -> {
                val kind = call.argument<String>("kind") ?: ""
                result.success(openPermissionSettings(kind))
            }
            "getInstalledApps" -> loadInstalledAppsAsync(result)
            "startOrUpdateGuard" -> {
                val remainingSeconds = call.argument<Int>("remainingSeconds") ?: 60
                val dndEnabled = call.argument<Boolean>("dndEnabled") ?: false
                val appLockEnabled = call.argument<Boolean>("appLockEnabled") ?: false
                val blacklisted = call.argument<List<String>>("blacklistedPackages") ?: emptyList()
                val taskTitle = call.argument<String>("taskTitle")
                startOrUpdateGuard(remainingSeconds, dndEnabled, appLockEnabled, blacklisted, taskTitle)
                result.success(null)
            }
            "stopGuard" -> {
                stopGuard()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun checkPermissions(): Map<String, Boolean> {
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager

        val dndGranted = notificationManager.isNotificationPolicyAccessGranted
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                context.packageName
            )
        }
        val usageAccessGranted = mode == AppOpsManager.MODE_ALLOWED
        val overlayGranted = Settings.canDrawOverlays(context)
        val notificationsGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED &&
                notificationManager.areNotificationsEnabled()
        } else {
            notificationManager.areNotificationsEnabled()
        }

        return mapOf(
            "dndGranted" to dndGranted,
            "usageAccessGranted" to usageAccessGranted,
            "overlayGranted" to overlayGranted,
            "notificationsGranted" to notificationsGranted
        )
    }

    private fun openPermissionSettings(kind: String): Boolean {
        val packageUri = Uri.parse("package:${context.packageName}")
        val intent = when (kind) {
            "dnd" -> Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            "usageAccess" -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS, packageUri)
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri)
            "notifications" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            }
            else -> return false
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            if (kind == "usageAccess" || kind == "overlay") {
                try {
                    val fallbackAction = if (kind == "usageAccess") {
                        Settings.ACTION_USAGE_ACCESS_SETTINGS
                    } else {
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION
                    }
                    context.startActivity(
                        Intent(fallbackAction).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    true
                } catch (e: Exception) {
                    Log.w(TAG, "Failed opening settings for $kind: ${e.message}")
                    false
                }
            } else {
                false
            }
        }
    }

    private fun loadInstalledAppsAsync(result: MethodChannel.Result) {
        ioExecutor.execute {
            try {
                val pm = context.packageManager
                val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_LAUNCHER)
                }
                val resolveInfos = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    pm.queryIntentActivities(
                        launcherIntent,
                        PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong())
                    )
                } else {
                    @Suppress("DEPRECATION")
                    pm.queryIntentActivities(launcherIntent, 0)
                }

                val seen = HashSet<String>()
                val apps = mutableListOf<Map<String, Any>>()
                for (resolveInfo in resolveInfos) {
                    val appInfo = resolveInfo.activityInfo?.applicationInfo ?: continue
                    val pkg = appInfo.packageName ?: continue
                    if (pkg == context.packageName || !seen.add(pkg)) continue
                    val label = resolveInfo.loadLabel(pm).toString().trim()
                    val isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                    apps.add(
                        mapOf(
                            "packageName" to pkg,
                            "appName" to if (label.isNotEmpty()) label else pkg,
                            "isSystemApp" to isSystem
                        )
                    )
                }

                apps.sortBy { (it["appName"] as String).lowercase() }
                mainHandler.post { result.success(apps) }
            } catch (e: Exception) {
                Log.e(TAG, "Failed querying installed apps: ${e.message}")
                mainHandler.post {
                    result.error("QUERY_APPS_FAILED", e.message, null)
                }
            }
        }
    }

    private fun startOrUpdateGuard(
        remainingSeconds: Int,
        dndEnabled: Boolean,
        appLockEnabled: Boolean,
        blacklistedPackages: List<String>,
        taskTitle: String?
    ) {
        val intent = Intent(context, FocusGuardService::class.java).apply {
            action = FocusGuardService.ACTION_START_OR_UPDATE
            putExtra(FocusGuardService.EXTRA_REMAINING_SECONDS, remainingSeconds)
            putExtra(FocusGuardService.EXTRA_DND_ENABLED, dndEnabled)
            putExtra(FocusGuardService.EXTRA_APP_LOCK_ENABLED, appLockEnabled)
            putStringArrayListExtra(
                FocusGuardService.EXTRA_BLACKLISTED_PACKAGES,
                ArrayList(blacklistedPackages)
            )
            if (taskTitle != null) {
                putExtra(FocusGuardService.EXTRA_TASK_TITLE, taskTitle)
            }
        }
        context.startForegroundService(intent)
    }

    private fun stopGuard() {
        // stopService invokes Service.onDestroy() safely if running and is a no-op otherwise,
        // avoiding startForegroundService requirements when simply turning protections off.
        context.stopService(Intent(context, FocusGuardService::class.java))
    }
}
