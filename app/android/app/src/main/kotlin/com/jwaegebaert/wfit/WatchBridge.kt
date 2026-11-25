package com.jwaegebaert.wfit

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.wear.remote.interactions.RemoteActivityHelper
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Phone side of the watch link (Dart: `lib/features/watch`). Passes JSON through unchanged: the snapshot goes out as
 * one data item, events come in as data items the watch owns. Data items are kept by Google Play services, so nothing
 * is lost while the watch is out of reach or this app is closed.
 */
class WatchBridge(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler, DataClient.OnDataChangedListener {
    private val context = context.applicationContext
    private val channel = MethodChannel(messenger, "wfit/watch").also { it.setMethodCallHandler(this) }
    private val data: DataClient = Wearable.getDataClient(this.context)
    private val main = Handler(Looper.getMainLooper())

    init {
        current = this
        data.addListener(this)
    }

    fun close() {
        data.removeListener(this)
        channel.setMethodCallHandler(null)
        if (current === this) current = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> GoogleApiAvailability.getInstance().checkApiAvailability(data)
                .addOnSuccessListener { result.success(true) }
                .addOnFailureListener { result.success(false) }

            "publish" -> {
                val request = PutDataRequest.create(SNAPSHOT).setUrgent()
                request.data = (call.arguments as String).toByteArray()
                data.putDataItem(request)
                    .addOnSuccessListener { result.success(null) }
                    .addOnFailureListener { result.error("publish", it.message, null) }
            }

            "pending" -> data.dataItems
                .addOnSuccessListener { items ->
                    val messages = items.filter(::isFromWatch).mapNotNull(::json)
                    items.release()
                    result.success(messages)
                }
                .addOnFailureListener { result.error("pending", it.message, null) }

            "open" -> {
                openOnWatch()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onDataChanged(events: DataEventBuffer) = deliver(events)

    private fun openOnWatch() {
        Wearable.getCapabilityClient(context).getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener { info ->
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("wfit://workout")).addCategory(Intent.CATEGORY_BROWSABLE)
                val helper = RemoteActivityHelper(context)
                for (node in info.nodes) {
                    // A refusal (watch locked, app just removed) surfaces in the future; nothing to do about it.
                    helper.startRemoteActivity(intent, node.id)
                }
            }
    }

    private fun send(json: String) {
        main.post { channel.invokeMethod("message", json) }
    }

    companion object {
        private const val SNAPSHOT = "/wfit/session"
        private const val EVENTS = "/wfit/event/"
        private const val TIMER = "/wfit/timer"
        private const val WATCH_CAPABILITY = "wfit_watch"

        /** Bridge of the running Flutter engine; null while the app is closed. */
        private var current: WatchBridge? = null

        private fun isFromWatch(item: DataItem): Boolean {
            val path = item.uri.path ?: return false
            return path.startsWith(EVENTS) || path == TIMER
        }

        private fun json(item: DataItem): String? = item.data?.decodeToString()

        fun deliver(events: DataEventBuffer) {
            for (event in events) {
                if (event.type != DataEvent.TYPE_CHANGED || !isFromWatch(event.dataItem)) continue
                json(event.dataItem)?.let { current?.send(it) }
            }
        }
    }
}

/**
 * Wakes the app when something changes on the watch while the phone is asleep. Without a running Flutter engine there
 * is nothing to do: the data items stay and are handled when the app is opened.
 */
class WatchListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) = WatchBridge.deliver(events)
}
