package com.jwaegebaert.wfit.watch

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.jwaegebaert.wfit.watch.core.Paths

/**
 * Debug builds only: plays the phone's part on an emulator without one, by storing a snapshot in the Data Layer.
 * adb shell am broadcast -n com.jwaegebaert.wfit/.watch.DebugReceiver --es snapshot (base64 of a snapshot)
 */
class DebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val text = intent.getStringExtra("snapshot") ?: return
        val request = PutDataRequest.create(Paths.SNAPSHOT).setUrgent()
        request.data = Base64.decode(text, Base64.DEFAULT)
        Wearable.getDataClient(context).putDataItem(request)
    }
}
