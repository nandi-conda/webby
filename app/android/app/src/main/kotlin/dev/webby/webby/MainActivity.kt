package dev.webby.webby

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
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
// "notificationClicked" with the notification's id. "memoryPressure" passes on onTrimMemory levels.
//
// The Flutter engine (and so the Dart app and its tabs) belongs to the process, not to this activity: Back on the last
// page, or Android dropping the activity, would otherwise end the engine while Ladybird's views and their WebContent
// processes live on, and the next start would open a second browser beside the orphaned one.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val permissionResults = mutableListOf<MethodChannel.Result>()
    // Whether this activity is coming back (from recents or after Android dropped it) rather than being opened anew;
    // then its intent is the one it was first opened with, and its link was already handled.
    private var reopened = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before any Dart runs: Ladybird and the app read their directories from the environment.
        LadybirdRuntime.setEnvironment(this)
        reopened = savedInstanceState != null ||
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        engine ?: FlutterEngine(context.applicationContext).also { engine = it }

    // Android asking for memory back: the app collects its pages' garbage and drops background tabs' pages (see
    // _onMemoryPressure in main.dart). Flutter's own memory-pressure signal only covers some of these levels.
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        channel?.invokeMethod("memoryPressure", level)
    }

    override fun onLowMemory() {
        super.onLowMemory()
        // TRIM_MEMORY_RUNNING_CRITICAL
        channel?.invokeMethod("memoryPressure", 15)
    }

    // Back on the last page leaves the browser running in the background instead of closing it.
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val running = flutterEngine.dartExecutor.isExecutingDart
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
                "initialUrl" -> result.success(if (reopened) null else viewedUrl(intent))
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
        // The app is already running, so it won't ask for "initialUrl": hand it this activity's link instead.
        if (running && !reopened) viewedUrl(intent)?.let { channel.invokeMethod("openUrl", it) }
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
        // Tapping it brings the app back (singleTask: onNewIntent) and tells the page.
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
        private var engine: FlutterEngine? = null
        private const val NOTIFICATION_CHANNEL = "sites"
        private const val NOTIFICATION_TAG = "site"
        private const val EXTRA_NOTIFICATION = "dev.webby.notification"
        private const val NOTIFICATION_PERMISSION_REQUEST = 1
    }

    private fun viewedUrl(intent: Intent?): String? =
        intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString
}
