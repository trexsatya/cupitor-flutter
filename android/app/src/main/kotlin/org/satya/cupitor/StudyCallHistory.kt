package org.satya.cupitor

import android.app.Activity
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

/** A notification tap survives engine startup; only the host can consume it. */
object StudyCallHistory {
    const val ACTION = "org.satya.cupitor.OPEN_STUDY_CALL_HISTORY"
    private var channel: MethodChannel? = null

    fun intent(context: Context, row: JSONObject): Intent = Intent(context, MainActivity::class.java)
        // A per-call action gives PendingIntents distinct identities without
        // a data URI that Flutter would interpret as an initial named route.
        .setAction("$ACTION/${row.getString("id")}")
        .putExtra("profile_id", row.getInt("profile_id"))
        .putExtra("open_id", UUID.randomUUID().toString())
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun install(activity: Activity, messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "cupitor/study_call_history").also { bridge ->
            bridge.setMethodCallHandler { call, reply ->
                if (call.method == "takePendingOpen") reply.success(takePendingOpen(activity))
                else reply.notImplemented()
            }
        }
        capture(activity, activity.intent)
    }

    @Synchronized fun capture(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (!action.startsWith("$ACTION/")) return
        val id = action.removePrefix("$ACTION/").takeIf { it.isNotBlank() && it.length <= 128 } ?: return
        val profile = intent.getIntExtra("profile_id", -1).takeIf { it > 0 } ?: return
        val openId = intent.getStringExtra("open_id")?.takeIf { it.isNotBlank() && it.length <= 128 } ?: return
        val prefs = context.getSharedPreferences("study_call_history", Context.MODE_PRIVATE)
        if (prefs.getString("consumed_open_id", null) == openId) return
        val pending = JSONObject().put("id", id).put("profile_id", profile).put("open_id", openId)
        check(prefs.edit()
            .putString("pending_open", pending.toString()).commit()) { "storage_error" }
        // Startup may precede the Dart handler. The durable pending value is
        // also checked on initialization/resume, so this nudge is optional.
        try { channel?.invokeMethod("pending", null) } catch (_: Exception) { }
    }

    @Synchronized fun takePendingOpen(context: Context): Map<String, Any>? {
        val prefs = context.getSharedPreferences("study_call_history", Context.MODE_PRIVATE)
        val raw = prefs.getString("pending_open", null) ?: return null
        val pending = try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
        check(prefs.edit().remove("pending_open").putString("consumed_open_id", pending.optString("open_id")).commit()) { "storage_error" }
        val id = pending.optString("id").takeIf { it.isNotBlank() } ?: return null
        val profile = pending.optInt("profile_id").takeIf { it > 0 } ?: return null
        return mapOf("id" to id, "profile_id" to profile, "open_id" to pending.optString("open_id"))
    }
}
