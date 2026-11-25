package com.jwaegebaert.wfit

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity: the health plugin requests Health Connect permissions with registerForActivityResult.
class MainActivity : FlutterFragmentActivity() {
    private var watch: WatchBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        watch = WatchBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        watch?.close()
        watch = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
