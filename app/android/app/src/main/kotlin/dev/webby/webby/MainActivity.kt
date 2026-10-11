package dev.webby.webby

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// The "webby/android" channel (lib/src/android.dart): "prepare" unpacks Ladybird before the app starts it,
// "initialUrl" is the link the app was opened with, and "openUrl" sends links that arrive later.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

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
                else -> result.notImplemented()
            }
        }
        this.channel = channel
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        viewedUrl(intent)?.let { channel?.invokeMethod("openUrl", it) }
    }

    private fun viewedUrl(intent: Intent?): String? =
        intent?.takeIf { it.action == Intent.ACTION_VIEW }?.dataString
}
