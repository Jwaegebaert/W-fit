package com.jwaegebaert.wfit.watch.link

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.WearableListenerService
import com.jwaegebaert.wfit.watch.core.Paths
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/** Receives the phone's snapshots, also while the app is closed, so a countdown started on the phone still vibrates. */
class PhoneListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        val texts = events
            .filter { it.type == DataEvent.TYPE_CHANGED && it.dataItem.uri.path == Paths.SNAPSHOT }
            .mapNotNull { it.dataItem.data?.decodeToString() }
        if (texts.isEmpty()) return
        val store = WorkoutStore.get(this)
        // Called on a background thread; the store is changed on the main thread only.
        runBlocking {
            withContext(Dispatchers.Main) {
                store.load()
                texts.forEach(store::receive)
            }
        }
    }
}
