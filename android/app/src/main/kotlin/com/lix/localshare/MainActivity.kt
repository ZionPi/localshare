package com.lix.localshare

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localshare/lifecycle")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "closeApp" -> {
                        runOnUiThread {
                            finishAndRemoveTask()
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
