package dev.webby.webby

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// The "webby/android" channel (lib/src/android.dart): "prepare" unpacks Ladybird before the app starts it,
// "initialUrl" is the link the app was opened with, and "openUrl" sends links that arrive later. Sites' notifications:
// "requestNotificationPermission", "showNotification" and "cancelNotification"; a tap comes back as
// "notificationClicked" with the notification's id.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val permissionResults = mutableListOf<MethodChannel.Result>()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before any Dart runs: Ladybird and the app read their directories from the environment.
        LadybirdRuntime.setEnvironment(this)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "webby/android")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val main = Handler(Looper.getMainLooper())
                    Thread {
                        try {
                            val paths = LadybirdRuntime.prepare(this)
                            main.post { result.success(paths) }
                        } catch (error: Exception) {
                            main.post { result.error("prepare", error.toString(), null) }
                        }
                    }.start()
                }
                "initialUrl" -> result.success(viewedUrl(intent))
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "showNotification" -> {
                    showNotification(
                        call.argument<Int>("id") ?: 0,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: "",
                        call.argument<String>("site") ?: "",
                    )
                    result.success(null)
                }
                "cancelNotification" -> {
                    (call.arguments as? Int)?.let { notificationManager().cancel(NOTIFICATION_TAG, it) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        this.channel = channel
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        viewedUrl(intent)?.let { channel?.invokeMethod("openUrl", it) }
        if (intent.hasExtra(EXTRA_NOTIFICATION)) {
            channel?.invokeMethod("notificationClicked", intent.getIntExtra(EXTRA_NOTIFICATION, 0))
        }
    }

    private fun notificationManager() = getSystemService(NotificationManager::class.java)

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(notificationManager().areNotificationsEnabled())
            return
        }
        permissionResults.add(result)
        if (permissionResults.size == 1) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        permissionResults.forEach { it.success(granted) }
        permissionResults.clear()
    }

    private fun showNotification(id: Int, title: String, body: String, site: String) {
        val manager = notificationManager()
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(NOTIFICATION_CHANNEL, "Sites", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        // Tapping it brings the app back (singleTop: onNewIntent) and tells the page.
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_NOTIFICATION, id)
        val pending = PendingIntent.getActivity(
            this, id, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(if (body.isEmpty()) site else body)
            .setSubText(site)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_TAG, id, notification)
    }

    companion object {
        private const val NOTIFICATION_CHANNEL = "sites"
        private const val NOTIFICATION_TAG = "site"
        private const val EXTRA_NOTIFICATION = "dev.webby.notification"
        private const val NOTIFICATION_PERMISSION_REQUEST = 1
    }

    private fun viewedUrl(intent: Intent?): String? =
        intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString
}
