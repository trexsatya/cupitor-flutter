package org.satya.cupitor

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.UUID

/** Local reminders, deliberately separate from SIM/Telecom calls. Android owns
 * delivery and durable results so neither Flutter nor a live page is required. */
object StudyCalls {
    const val CHANNEL = "cupitor_study_calls_v1"
    const val RING_MS = 45_000L
    const val MAX_HISTORY = 100
    const val DEFAULT_PENDING_LIMIT = 50
    const val MAX_PENDING_LIMIT = 5000
    const val MAX_ARMED = 50
    private const val PERMISSION_REQUEST = 4301
    private var permissionReply: MethodChannel.Result? = null
    var visibleCallId: String? = null
    private val terminal = setOf("completed", "failed", "declined", "missed", "cancelled", "interrupted")

    fun install(activity: Activity, messenger: BinaryMessenger) {
        cancelObsoletePlaylistCalls(activity)
        rearmBestEffort(activity)
        MethodChannel(messenger, "cupitor/study_calls").setMethodCallHandler { call, reply ->
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val profile = (args["profile_id"] as? Number)?.toInt() ?: 1
                when (call.method) {
                    "getCapabilities" -> reply.success(mapOf(
                        "supported" to true, "permission" to permission(activity),
                        "full_screen" to fullScreenAllowed(activity),
                        "exact_alarms" to exactAllowed(activity),
                        "speech_input" to StudyCallVoice.available(activity),
                        "answer_types" to listOf("choice", "text"),
                        "default_retries" to StudyCallAnswer.DEFAULT_RETRIES,
                        "batch_schedule" to true, "edit_scheduled" to true, "pending_controls" to true, "history_limit" to MAX_HISTORY,
                        "voice_selection" to true,
                        "settings" to true, "pending_limit" to pendingLimit(activity),
                        "max_pending_limit" to MAX_PENDING_LIMIT, "armed_limit" to MAX_ARMED,
                        "pending_count" to read(activity).count { it.optString("status") !in terminal },
                    ) + StudyCallSpeech.defaults(activity))
                    "setSettings" -> {
                        setSettings(activity, args)
                        reply.success(mapOf("pending_limit" to pendingLimit(activity)) + StudyCallSpeech.defaults(activity))
                    }
                    "getVoices" -> StudyCallSpeech.getVoices(activity, reply)
                    "previewVoice" -> {
                        check(visibleCallId == null && read(activity).none { it.optString("status") in setOf("ringing", "answered") }) { "busy" }
                        StudyCallSpeech.preview(activity, args, reply)
                    }
                    "stopVoicePreview" -> { StudyCallSpeech.stopPreview(); reply.success(true) }
                    "openVoiceSettings" -> {
                        try { activity.startActivity(Intent("com.android.settings.TTS_SETTINGS")) }
                        catch (_: Exception) { activity.startActivity(Intent(Settings.ACTION_SETTINGS)) }
                        reply.success(true)
                    }
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 && permission(activity) != "granted") {
                            if (permissionReply != null) error("busy")
                            permissionReply = reply
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
                        } else reply.success(mapOf("permission" to permission(activity)))
                    }
                    "openFullScreenSettings", "openAlarmSettings" -> {
                        val action = if (call.method == "openFullScreenSettings" && Build.VERSION.SDK_INT >= 34)
                            Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT
                        else if (call.method == "openAlarmSettings" && Build.VERSION.SDK_INT >= 31)
                            Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM
                        else Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                        activity.startActivity(Intent(action, Uri.parse("package:${activity.packageName}")))
                        reply.success(true)
                    }
                    "getCalls" -> reply.success(mapOf("version" to 1, "calls" to
                        read(activity).filter { it.optInt("profile_id") == profile }.map(::asMap)))
                    "callNow", "schedule" -> {
                        check(permission(activity) == "granted") { "permission_denied" }
                        if (call.method == "callNow") check(visibleCallId == null && read(activity).none {
                            it.optString("status") in setOf("ringing", "answered")
                        }) { "busy" }
                        val data = validate(args, profile, call.method == "callNow")
                        check(read(activity).count { !terminal.contains(it.optString("status")) } < pendingLimit(activity)) { "too_many_calls" }
                        mutate(activity) { it.add(data) }
                        try {
                            if (call.method == "callNow") {
                                fire(activity, data.getString("id"))
                                activity.startActivity(screenIntent(activity, data.getString("id"), false))
                            } else rearmScheduled(activity)
                        } catch (e: Exception) {
                            update(activity, data.getString("id")) { it.put("status", "cancelled") }
                            dismiss(activity, data.getString("id"))
                            rearmBestEffort(activity)
                            throw e
                        }
                        reply.success(mapOf("id" to data.getString("id"), "exact" to exactAllowed(activity)))
                    }
                    "scheduleBatch" -> {
                        check(permission(activity) == "granted") { "permission_denied" }
                        val ids = scheduleBatch(activity, args["calls"], profile)
                        reply.success(mapOf("ids" to ids))
                    }
                    "update" -> {
                        check(permission(activity) == "granted") { "permission_denied" }
                        editScheduled(activity, args, profile)
                        reply.success(mapOf("id" to args["id"]))
                    }
                    "setEnabled" -> {
                        val id = args["id"] as? String ?: error("bad_payload")
                        val enabled = args["enabled"] as? Boolean ?: error("bad_payload")
                        if (enabled) check(permission(activity) == "granted") { "permission_denied" }
                        setEnabled(activity, id, profile, enabled)
                        reply.success(true)
                    }
                    "remove" -> {
                        removePending(activity, args["id"] as? String ?: error("bad_payload"), profile)
                        reply.success(true)
                    }
                    "cancel" -> {
                        val id = args["id"] as? String ?: error("bad_payload")
                        val row = read(activity).find { it.optString("id") == id && it.optInt("profile_id") == profile }
                            ?: error("unknown_call")
                        if (!terminal.contains(row.optString("status"))) {
                            update(activity, id) { it.put("status", "cancelled").put("finished_at", System.currentTimeMillis()) }
                            dismiss(activity, id)
                            rearmBestEffort(activity)
                        }
                        reply.success(true)
                    }
                    else -> reply.notImplemented()
                }
            } catch (e: Exception) {
                reply.error(e.message?.takeIf { it.matches(Regex("[a-z_]+")) } ?: "internal", null, null)
            }
        }
    }

    fun pendingLimit(context: Context): Int = context.getSharedPreferences("study_calls", Context.MODE_PRIVATE)
        .getInt("pending_limit", DEFAULT_PENDING_LIMIT).coerceIn(1, MAX_PENDING_LIMIT)

    fun setPendingLimit(context: Context, raw: Any?) = setSettings(context, mapOf("pending_limit" to raw))

    fun setSettings(context: Context, args: Map<*, *>) {
        val voice = StudyCallSpeech.validate(args)
        val limit = if (args.containsKey("pending_limit")) {
            val value = args["pending_limit"] as? Number ?: error("bad_limit")
            check(value.toDouble() == value.toInt().toDouble() && value.toInt() in 1..MAX_PENDING_LIMIT) { "bad_limit" }
            value.toInt()
        } else pendingLimit(context)
        val edit = context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit().putInt("pending_limit", limit)
        voice["voice_name"]?.let { edit.putString("voice_name", it as String) }
        voice["speech_rate"]?.let { edit.putFloat("speech_rate", (it as Number).toFloat()) }
        check(edit.commit()) { "storage_error" }
        // Lowering the limit never removes existing questions. It only blocks additions.
    }

    fun alarmPlan(context: Context): List<JSONObject> = read(context)
        .filter { it.optString("status") == "scheduled" }
        .sortedWith(compareBy<JSONObject> { it.optLong("when_ms") }.thenBy { it.optLong("created_at") })
        .take(MAX_ARMED)

    @Synchronized fun rearmScheduled(context: Context, armCall: (Context, JSONObject) -> Unit = ::arm) {
        val rows = read(context)
        val prefs = context.getSharedPreferences("study_calls", Context.MODE_PRIVATE)
        // Before this setting existed there could be at most 50 pending calls.
        // Never issue thousands of AlarmManager binder calls for stored-only rows.
        val oldIds = prefs.getStringSet("armed_ids", null)?.toSet() ?: rows
            .filter { it.optString("status") in setOf("scheduled", "disabled") }
            .take(MAX_ARMED).map { it.getString("id") }.toSet()
        val next = rows.filter { it.optString("status") == "scheduled" }
            .sortedWith(compareBy<JSONObject> { it.optLong("when_ms") }.thenBy { it.optLong("created_at") })
            .take(MAX_ARMED)
        val nextIds = next.map { it.getString("id") }.toSet()
        // Keep both windows during a transition so a process death or failed
        // arm can be repaired without losing track of an installed alarm.
        check(prefs.edit().putStringSet("armed_ids", oldIds + nextIds).commit()) { "storage_error" }
        oldIds.forEach { alarms(context).cancel(alarmIntent(context, it)) }
        next.forEach { armCall(context, it) }
        check(prefs.edit().putStringSet("armed_ids", nextIds).commit()) { "storage_error" }
    }

    fun rearmBestEffort(context: Context) {
        try { rearmScheduled(context) } catch (_: Exception) {}
    }

    @Synchronized fun scheduleBatch(context: Context, raw: Any?, profile: Int,
                                   armCall: (Context, JSONObject) -> Unit = ::arm): List<String> {
        val calls = raw as? List<*> ?: error("bad_payload")
        check(calls.size in 1..MAX_PENDING_LIMIT) { "bad_payload" }
        // Validate every question/time before changing storage or arming anything.
        val added = calls.map { validate(it as? Map<*, *> ?: error("bad_payload"), profile, false) }
        check(read(context).count { it.optString("status") !in terminal } + added.size <= pendingLimit(context)) { "too_many_calls" }
        mutate(context) { it.addAll(added) }
        try { rearmScheduled(context, armCall) }
        catch (e: Exception) {
            val ids = added.map { it.getString("id") }.toSet()
            added.forEach { dismiss(context, it.getString("id")) }
            mutate(context) { rows -> rows.removeAll { it.optString("id") in ids } }
            rearmBestEffort(context)
            throw e
        }
        return added.map { it.getString("id") }
    }

    @Synchronized fun editScheduled(context: Context, args: Map<*, *>, profile: Int,
                                   armCall: (Context, JSONObject) -> Unit = ::arm) {
        val id = args["id"] as? String ?: error("bad_payload")
        val old = find(context, id)?.takeIf { it.optInt("profile_id") == profile } ?: error("unknown_call")
        check(old.optString("status") in setOf("scheduled", "disabled")) { "not_scheduled" }
        val replacement = validate(args, profile, false).put("id", id).put("created_at", old.getLong("created_at"))
        dismiss(context, id)
        mutate(context) { rows -> rows.removeAll { it.optString("id") == id }; rows.add(replacement) }
        try { rearmScheduled(context, armCall) }
        catch (e: Exception) {
            mutate(context) { rows -> rows.removeAll { it.optString("id") == id }; rows.add(old) }
            rearmBestEffort(context)
            throw e
        }
    }

    @Synchronized fun setEnabled(context: Context, id: String, profile: Int, enabled: Boolean) {
        val old = find(context, id)?.takeIf { it.optInt("profile_id") == profile } ?: error("unknown_call")
        check(old.optString("status") in setOf("scheduled", "disabled")) { "not_scheduled" }
        if (enabled) check(old.getLong("when_ms") > System.currentTimeMillis()) { "bad_time" }
        if ((old.optString("status") == "scheduled") == enabled) return
        val previous = JSONObject(old.toString())
        dismiss(context, id)
        update(context, id) { it.put("enabled", enabled).put("status", if (enabled) "scheduled" else "disabled") }
        if (!enabled) { rearmBestEffort(context); return }
        try { rearmScheduled(context) } catch (e: Exception) {
            mutate(context) { rows -> rows.removeAll { it.optString("id") == id }; rows.add(previous) }
            rearmBestEffort(context)
            throw e
        }
    }

    @Synchronized fun removePending(context: Context, id: String, profile: Int) {
        val old = find(context, id)?.takeIf { it.optInt("profile_id") == profile } ?: error("unknown_call")
        check(old.optString("status") in setOf("scheduled", "disabled")) { "not_scheduled" }
        dismiss(context, id)
        mutate(context) { rows -> rows.removeAll { it.optString("id") == id } }
        rearmBestEffort(context)
    }

    fun cancelObsoletePlaylistCalls(context: Context) {
        read(context).filter { it.has("notif_id") && it.optString("status") !in terminal }.forEach {
            finish(context, it.getString("id"), "cancelled")
        }
    }

    fun onPermissionResult(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionReply?.success(mapOf("permission" to
            if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) "granted" else "denied"))
        permissionReply = null
        return true
    }

    fun permission(context: Context): String = if (
        (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) ||
        !manager(context).areNotificationsEnabled() ||
        (Build.VERSION.SDK_INT >= 26 && manager(context).getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE)
    ) "denied" else "granted"

    fun fullScreenAllowed(context: Context) = Build.VERSION.SDK_INT < 34 || manager(context).canUseFullScreenIntent()
    fun exactAllowed(context: Context) = Build.VERSION.SDK_INT < 31 || alarms(context).canScheduleExactAlarms()
    private fun manager(context: Context) = requireNotNull(context.getSystemService(NotificationManager::class.java))
    private fun alarms(context: Context) = requireNotNull(context.getSystemService(AlarmManager::class.java))

    fun validate(args: Map<*, *>, profile: Int, immediate: Boolean, now: Long = System.currentTimeMillis()): JSONObject {
        fun text(key: String, limit: Int): String {
            val s = (args[key] as? String)?.trim() ?: error("bad_payload")
            check(s.isNotEmpty() && s.length <= limit) { "bad_payload" }
            return s
        }
        val title = text("title", 120)
        val question = text("question", 4000)
        check(!args.containsKey("response_type") || args["response_type"] is String) { "bad_payload" }
        val type = args["response_type"] as? String ?: "choice"
        check(type in setOf("choice", "text")) { "bad_payload" }
        val choices = if (type == "text") emptyList<Any>() else args["choices"] as? List<*> ?: error("bad_payload")
        check(type == "text" || choices.size in 2..9) { "bad_payload" }
        val labels = choices.map {
            val s = (it as? String)?.trim() ?: error("bad_payload")
            check(s.isNotEmpty() && s.length <= 200) { "bad_payload" }; s
        }
        val language = (args["language"] as? String) ?: "sv-SE"
        check(language.matches(Regex("[a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?"))) { "bad_payload" }
        check(!args.containsKey("voice_response") || args["voice_response"] is Boolean) { "bad_payload" }
        val retries = if (args.containsKey("max_retries")) {
            val value = args["max_retries"] as? Number ?: error("bad_payload")
            check(value.toDouble() == value.toInt().toDouble() && value.toInt() in 0..StudyCallAnswer.MAX_RETRIES) { "bad_payload" }
            value.toInt()
        } else StudyCallAnswer.DEFAULT_RETRIES
        val threshold = if (args.containsKey("match_threshold")) {
            val value = (args["match_threshold"] as? Number)?.toDouble() ?: error("bad_payload")
            check(value.isFinite() && value in 0.7..1.0) { "bad_payload" }
            value
        } else StudyCallAnswer.DEFAULT_MATCH_THRESHOLD
        val correctIndex = if (type == "choice" && args.containsKey("correct_choice_index")) {
            val value = args["correct_choice_index"] as? Number ?: error("bad_payload")
            check(value.toDouble() == value.toInt().toDouble() && value.toInt() in labels.indices) { "bad_payload" }
            value.toInt()
        } else null
        val accepted = if (type == "text") {
            val values = args["accepted_answers"] as? List<*> ?: error("bad_payload")
            check(values.size in 1..20) { "bad_payload" }
            values.map {
                val value = (it as? String)?.trim() ?: error("bad_payload")
                check(value.length in 1..500 && StudyCallAnswer.normalize(value).isNotEmpty()) { "bad_payload" }
                value
            }
        } else emptyList()
        check(!args.containsKey("enabled") || args["enabled"] is Boolean) { "bad_payload" }
        val enabled = args["enabled"] as? Boolean ?: true
        check(!immediate || enabled) { "bad_payload" }
        val whenMs = if (immediate) now else (args["when_ms"] as? Number)?.toLong() ?: error("bad_payload")
        check(immediate || (whenMs > now && whenMs <= now + 366L * 24 * 60 * 60 * 1000)) { "bad_time" }
        val row = JSONObject().put("id", UUID.randomUUID().toString()).put("profile_id", profile)
            .put("title", title).put("question", question).put("choices", JSONArray(labels))
            .put("language", language).put("when_ms", whenMs).put("created_at", now)
            .put("voice_response", args["voice_response"] as? Boolean ?: true)
            .put("response_type", type).put("max_retries", retries).put("attempts", JSONArray())
            .put("match_threshold", threshold)
            .put("accepted_answers", JSONArray(accepted))
            .put("enabled", enabled).put("status", if (enabled) "scheduled" else "disabled")
        StudyCallSpeech.validate(args).forEach { (key, value) -> row.put(key, value) }
        if (correctIndex != null) row.put("correct_choice_index", correctIndex)
        return row
    }

    /** Single small store, all entry points run in this app process. commit()
     * makes a result durable before the activity finishes or a receiver exits. */
    @Synchronized fun read(context: Context): MutableList<JSONObject> {
        val a = try { JSONArray(context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).getString("calls", "[]")) }
            catch (_: Exception) { JSONArray() }
        val now = System.currentTimeMillis()
        val rows = (0 until a.length()).map { a.getJSONObject(it) }.toMutableList()
        var changed = false
        rows.forEach {
            if (it.optString("status") == "ringing" && now - it.optLong("fired_at") >= RING_MS) {
                it.put("status", "missed").put("finished_at", now); changed = true
            } else if (it.optString("status") == "answered" &&
                (visibleCallId != it.optString("id") || now - it.optLong("answered_at") > 10 * 60_000)) {
                it.put("status", "interrupted").put("finished_at", now); changed = true
            }
        }
        val capped = retained(rows)
        if (changed || capped.size != rows.size) save(context, capped)
        return capped.toMutableList()
    }

    private fun retained(rows: List<JSONObject>): List<JSONObject> {
        val active = rows.filter { !terminal.contains(it.optString("status")) }
        val history = rows.filter { terminal.contains(it.optString("status")) }
            .sortedBy { it.optLong("finished_at", it.optLong("created_at")) }.takeLast(MAX_HISTORY)
        return active + history
    }

    private fun save(context: Context, rows: List<JSONObject>) {
        check(context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit()
            .putString("calls", JSONArray(retained(rows)).toString()).commit()) { "storage_error" }
    }

    @Synchronized private fun mutate(context: Context, fn: (MutableList<JSONObject>) -> Unit) {
        val rows = read(context); fn(rows); save(context, rows)
    }
    fun find(context: Context, id: String) = read(context).find { it.optString("id") == id }
    fun update(context: Context, id: String, fn: (JSONObject) -> Unit) = mutate(context) { rows ->
        rows.find { it.optString("id") == id }?.let(fn)
    }
    private fun jsonValue(value: Any?): Any? = when (value) {
            is JSONObject -> asMap(value)
            is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
            JSONObject.NULL -> null
            else -> value
        }
    private fun asMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { jsonValue(json.get(it)) }

    private fun alarmIntent(context: Context, id: String) = PendingIntent.getBroadcast(context, 0,
        Intent(context, StudyCallReceiver::class.java).setAction("fire")
            .setData(Uri.parse("cupitor-study-call://alarm/$id")).putExtra("id", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun expiryIntent(context: Context, id: String) = PendingIntent.getBroadcast(context, 0,
        Intent(context, StudyCallReceiver::class.java).setAction("expire")
            .setData(Uri.parse("cupitor-study-call://expire/$id")).putExtra("id", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun arm(context: Context, row: JSONObject) {
        val pending = alarmIntent(context, row.getString("id"))
        val whenMs = row.getLong("when_ms")
        if (exactAllowed(context)) alarms(context).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMs, pending)
        else alarms(context).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMs, pending)
    }

    fun screenIntent(context: Context, id: String, answer: Boolean) = Intent(context, StudyCallActivity::class.java)
        .setData(Uri.parse("cupitor-study-call://screen/$id/$answer"))
        .putExtra("id", id).putExtra("answer", answer)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    private fun screenPending(context: Context, id: String, answer: Boolean) = PendingIntent.getActivity(context, 0,
        screenIntent(context, id, answer), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    fun dismiss(context: Context, id: String) {
        alarms(context).cancel(alarmIntent(context, id))
        alarms(context).cancel(expiryIntent(context, id))
        manager(context).cancel(id, 1)
    }

    fun finish(context: Context, id: String, status: String, choice: Int? = null,
               responseMode: String = "tap", spokenResponse: String? = null) {
        if (status == "completed" && choice != null) {
            val labels = find(context, id)?.optJSONArray("choices") ?: return
            if (choice !in 0 until labels.length()) return
            respond(context, id, labels.getString(choice), choice, responseMode, spokenResponse)
            return
        }
        var settled = false
        update(context, id) {
            settled = terminal.contains(it.optString("status"))
            if (!terminal.contains(it.optString("status"))) {
                if (choice != null && (it.optString("status") != "answered" || choice !in 0 until it.getJSONArray("choices").length())) return@update
                it.put("status", status).put("finished_at", System.currentTimeMillis())
                if (choice != null) {
                    it.put("choice_index", choice).put("choice", it.getJSONArray("choices").getString(choice))
                        .put("response_mode", responseMode)
                    if (responseMode == "voice" && !spokenResponse.isNullOrBlank()) {
                        it.put("spoken_response", spokenResponse.trim().take(500))
                    }
                }
                settled = true
            }
        }
        if (settled) { dismiss(context, id); rearmBestEffort(context) }
    }

    /** Claim, grade and persist a final response together. Only an answered
     * call can accept it, so cancellation or an earlier correct answer wins. */
    fun respond(context: Context, id: String, answer: String, choice: Int? = null,
                responseMode: String = "tap", spokenResponse: String? = null,
                reason: String? = null): StudyCallResponse? {
        var result: StudyCallResponse? = null
        mutate(context) { rows ->
            val row = rows.find { it.optString("id") == id } ?: return@mutate
            if (row.optString("status") != "answered") return@mutate
            val type = row.optString("response_type", "choice")
            val labels = row.getJSONArray("choices")
            if (reason == null && type == "choice" && (choice == null || choice !in 0 until labels.length())) return@mutate
            if (reason == null && (answer.isBlank() || answer.length > 500)) return@mutate
            val correct: Boolean? = when {
                reason != null -> false
                type == "text" -> {
                    val accepted = row.getJSONArray("accepted_answers")
                    StudyCallAnswer.textIsCorrect(answer, (0 until accepted.length()).map { accepted.getString(it) },
                        row.optDouble("match_threshold", StudyCallAnswer.DEFAULT_MATCH_THRESHOLD))
                }
                row.has("correct_choice_index") -> choice == row.getInt("correct_choice_index")
                else -> null // older ungraded choice questions retain their behavior
            }
            val attempts = row.optJSONArray("attempts") ?: JSONArray()
            val now = System.currentTimeMillis()
            val attempt = JSONObject().put("answer", answer.trim().take(500)).put("response_mode", responseMode)
                .put("at", now).put("correct", correct ?: JSONObject.NULL)
            if (choice != null) attempt.put("choice_index", choice)
            if (reason != null) attempt.put("reason", reason)
            attempts.put(attempt)
            val maxRetries = row.optInt("max_retries", StudyCallAnswer.DEFAULT_RETRIES)
            val retry = StudyCallAnswer.shouldRetry(correct, attempts.length(), maxRetries)
            row.put("attempts", attempts).put("answer", answer.trim().take(500))
                .put("response_mode", responseMode).put("correct", correct ?: JSONObject.NULL)
            if (choice != null) row.put("choice_index", choice).put("choice", labels.getString(choice))
            else { row.remove("choice_index"); row.remove("choice") }
            if (responseMode == "voice" && !spokenResponse.isNullOrBlank()) row.put("spoken_response", spokenResponse.trim().take(500))
            else row.remove("spoken_response")
            if (!retry) row.put("status", if (correct == false) "failed" else "completed").put("finished_at", now)
            result = StudyCallResponse(correct, retry, attempts.length(), maxRetries + 1)
        }
        if (result?.retry == false) { dismiss(context, id); rearmBestEffort(context) }
        return result
    }

    fun fire(context: Context, id: String) {
        val row = find(context, id) ?: return
        if (row.optString("status") != "scheduled") return
        if (row.has("notif_id")) { finish(context, id, "cancelled"); return }
        // A queued alarm from before an edit must not ring the rescheduled call early.
        if (row.optLong("when_ms") > System.currentTimeMillis()) return
        if (System.currentTimeMillis() - row.optLong("when_ms") > 5 * 60_000) {
            finish(context, id, "missed"); return
        }
        // Avoid simultaneous ringing screens. An overlapping reminder is kept
        // as missed in history rather than replacing a question being answered.
        if (visibleCallId != null || read(context).any { it.optString("status") == "ringing" }) {
            finish(context, id, "missed"); return
        }
        if (permission(context) != "granted") { finish(context, id, "missed"); return }
        update(context, id) { it.put("status", "ringing").put("fired_at", System.currentTimeMillis()) }
        rearmBestEffort(context)
        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL, "Study calls", NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Questions you ask Cupitor to ring and read aloud"
            channel.setSound(sound, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
            channel.enableVibration(true)
            manager(context).createNotificationChannel(channel)
        }
        val decline = PendingIntent.getBroadcast(context, 0,
            Intent(context, StudyCallReceiver::class.java).setAction("decline")
                .setData(Uri.parse("cupitor-study-call://decline/$id")).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        builder.setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(row.getString("title")).setContentText("Incoming study call")
            .setCategory(Notification.CATEGORY_ALARM).setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setLocalOnly(true)
            .setContentIntent(screenPending(context, id, false)).setDeleteIntent(decline)
            .addAction(Notification.Action.Builder(null, "Answer", screenPending(context, id, true)).build())
            .addAction(Notification.Action.Builder(null, "Decline", decline).build())
        if (Build.VERSION.SDK_INT >= 26) builder.setTimeoutAfter(RING_MS)
        else builder.setSound(sound).setVibrate(longArrayOf(0, 400, 400))
        if (fullScreenAllowed(context)) builder.setFullScreenIntent(screenPending(context, id, false), true)
        val notification = builder.build()
        notification.flags = notification.flags or Notification.FLAG_INSISTENT
        manager(context).notify(id, 1, notification)
        // API 24–25 has no notification timeout. Exact alarms need no special
        // permission there; on newer versions setTimeoutAfter is the fallback.
        val expiry = System.currentTimeMillis() + RING_MS
        if (exactAllowed(context)) alarms(context).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiry, expiryIntent(context, id))
        else alarms(context).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, expiry, expiryIntent(context, id))
    }
}

class StudyCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
                StudyCalls.cancelObsoletePlaylistCalls(context)
                StudyCalls.rearmBestEffort(context)
                return
            }
            val id = intent.getStringExtra("id") ?: return
            when (intent.action) {
                "fire" -> StudyCalls.fire(context, id)
                "decline" -> StudyCalls.finish(context, id, "declined")
                "expire" -> if (StudyCalls.find(context, id)?.optString("status") in setOf("ringing", "missed")) {
                    StudyCalls.finish(context, id, "missed")
                }
            }
        } catch (_: Exception) { /* Receiver errors must not crash the host. */ }
    }
}

/** Scrollable native UI works while Flutter and the page are absent. Answer
 * reveals/speaks the question; optional voice replies use a bounded recognizer. */
class StudyCallActivity : Activity(), TextToSpeech.OnInitListener {
    companion object { private const val MICROPHONE_REQUEST = 4302 }
    private var id = ""
    private var tts: TextToSpeech? = null
    private var ready = false
    private var answered = false
    private var started = false
    private var needsInitialReading = true
    private var focus: AudioFocusRequest? = null
    private var callAudio: StudyCallAudio? = null
    private var audioStatus: TextView? = null
    private var speakerButton: Button? = null
    private var listenOnAudioReady = false
    private var lastReadUtterance: String? = null
    private val focusListener = AudioManager.OnAudioFocusChangeListener {
        if (it < 0) {
            needsInitialReading = true
            stopReading(); voice?.cancel()
            callAudio?.stop("Audio interrupted. Tap Read again to resume.")
        }
    }
    private lateinit var body: LinearLayout
    private lateinit var message: TextView
    private lateinit var voiceStatus: TextView
    private var voiceButton: Button? = null
    private var voice: StudyCallVoice? = null
    private var voiceResponse = true
    private var voiceAvailable = false
    private var pendingVoicePermission = false
    private var listenOnResume = false
    private var speechBatch = 0
    private var autoListenUtterance: String? = null
    private var responseType = "choice"
    private var answerEntry: EditText? = null
    private var acceptingAnswer = true
    private var finalFeedback = false
    private var retryFeedback = ""
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            if (finalFeedback) return
            val row = StudyCalls.find(this@StudyCallActivity, id)
            if (row == null || row.optString("status") !in setOf("ringing", "answered")) { finish(); return }
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        else window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        id = intent.getStringExtra("id") ?: run { finish(); return }
        StudyCalls.visibleCallId = id
        val row = StudyCalls.find(this, id)
        if (row == null || row.optString("status") !in setOf("ringing", "answered")) { finish(); return }
        answered = row.optString("status") == "answered"
        voiceResponse = row.optBoolean("voice_response", true)
        responseType = row.optString("response_type", "choice")
        voiceAvailable = StudyCallVoice.available(this)
        body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (24 * resources.displayMetrics.density).toInt(); setPadding(pad, pad, pad, pad)
            setBackgroundColor(Color.WHITE)
        }
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(body) })
        body.addView(TextView(this).apply { text = "Cupitor · Study call"; textSize = 16f; setTextColor(Color.DKGRAY) })
        body.addView(TextView(this).apply { text = row.getString("title"); textSize = 28f; setTextColor(Color.BLACK) })
        message = TextView(this).apply { textSize = 20f; setTextColor(Color.BLACK); setPadding(0, 24, 0, 24) }
        body.addView(message)
        voiceStatus = TextView(this).apply { textSize = 16f; setTextColor(Color.DKGRAY) }
        body.addView(voiceStatus)
        callAudio = StudyCallAudio(this, savedInstanceState?.getBoolean("study_speaker") == true) { state ->
            audioStatus?.text = "Audio: ${state.label}"
            speakerButton?.apply {
                text = if (state.speaker) "Speaker: on" else "Speaker: off"
                isSelected = state.speaker
                isEnabled = state.ready && state.canToggleSpeaker
            }
            if (!state.ready) {
                if (started && answered && !finalFeedback) {
                    if (lastReadUtterance != null) needsInitialReading = true
                    if (voice?.listening == true) listenOnAudioReady = true
                }
                stopReading(); voice?.cancel()
            } else handler.post {
                if (!isAnsweredAndResumed() || callAudio?.state?.ready != true) return@post
                if (listenOnAudioReady) { listenOnAudioReady = false; beginVoiceAnswer() }
                else if (ready && needsInitialReading) speak()
            }
        }
        voice = StudyCallVoice(this,
            isActive = { isAnsweredAndResumed() },
            onStatus = { showVoiceStatus(it) },
            onListening = { voiceButton?.text = if (it) "Stop listening" else "Answer by voice" },
            onResult = { acceptSpeech(it) },
            onFailure = { text, retryable ->
                if (retryable) recordAttempt("", responseMode = "voice", reason = "no_input")
                else showVoiceStatus(text)
            })
        render()
        StudyCallSpeech.stopPreview()
        tts = TextToSpeech(this, this)
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                handler.post {
                    if (utteranceId == lastReadUtterance) lastReadUtterance = null
                    if (utteranceId == null || utteranceId != autoListenUtterance) return@post
                    autoListenUtterance = null
                    val completedBatch = speechBatch
                    // Let the speaker's trailing audio settle before opening
                    // the microphone. Any intervening action invalidates this.
                    handler.postDelayed({
                        if (voiceResponse && completedBatch == speechBatch && isAnsweredAndResumed() &&
                            voice?.listening != true) beginVoiceAnswer()
                    }, 250)
                }
            }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                handler.post {
                    if (utteranceId == null || !utteranceId.startsWith("study-$id-$speechBatch-")) return@post
                    autoListenUtterance = null
                    if (isAnsweredAndResumed()) voiceStatus.text = "The question could not be read aloud. You can read it and answer on screen."
                }
            }
        })
        if (Build.VERSION.SDK_INT >= 33) onBackInvokedDispatcher.registerOnBackInvokedCallback(
            android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT
        ) { endCall() }
        handler.post(tick)
        if (intent.getBooleanExtra("answer", false) && !answered) answer()
    }

    private fun button(label: String, click: () -> Unit) = Button(this).also {
        it.text = label; it.isAllCaps = false; it.minHeight = (52 * resources.displayMetrics.density).toInt()
        it.setOnClickListener { click() }; body.addView(it)
    }

    private fun render() {
        while (body.childCount > 4) body.removeViewAt(4)
        voiceButton = null
        audioStatus = null; speakerButton = null
        answerEntry = null
        val row = StudyCalls.find(this, id) ?: return
        voiceStatus.visibility = if (answered) View.VISIBLE else View.GONE
        if (!answered) {
            message.text = "Incoming study call"
            button("Answer") { answer() }
            button("Decline") { StudyCalls.finish(this, id, "declined"); finish() }
        } else {
            message.text = row.getString("question")
            val audioState = callAudio?.state
            audioStatus = TextView(this).apply {
                text = "Audio: ${audioState?.label ?: "Connecting…"}"
                textSize = 16f; setTextColor(Color.DKGRAY)
            }.also { body.addView(it) }
            speakerButton = button(if (audioState?.speaker == true) "Speaker: on" else "Speaker: off") {
                callAudio?.let { it.setSpeaker(!it.state.speaker) }
            }.apply {
                contentDescription = "Toggle call speaker"
                isSelected = audioState?.speaker == true
                isEnabled = audioState?.ready == true && audioState.canToggleSpeaker
            }
            val choices = row.getJSONArray("choices")
            if (responseType == "text") {
                answerEntry = EditText(this).apply {
                    hint = "Your answer"
                    contentDescription = "Your answer"
                    setTextColor(Color.BLACK)
                    filters = arrayOf(android.text.InputFilter.LengthFilter(500))
                }.also { body.addView(it) }
                button("Submit answer") {
                    val value = answerEntry?.text?.toString().orEmpty().trim()
                    if (value.isBlank()) showVoiceStatus("Enter an answer, or answer by voice.")
                    else recordAttempt(value, responseMode = "typed")
                }
            } else {
                for (i in 0 until choices.length()) button("${i + 1}. ${choices.getString(i)}") {
                    completeChoice(i)
                }
            }
            if (voiceResponse && voiceAvailable) {
                showVoiceStatus(retryFeedback.ifBlank { if (responseType == "text") "After the question, say your answer."
                    else "After the question, say a number or an alternative." })
                voiceButton = button("Answer by voice") {
                    if (voice?.listening == true) {
                        voice?.cancel()
                        showVoiceStatus("Listening stopped. You can answer on screen or tap Answer by voice.")
                    } else beginVoiceAnswer()
                }
            } else if (voiceResponse) {
                showVoiceStatus("Speech recognition is unavailable. You can answer on screen.")
            } else showVoiceStatus(retryFeedback.ifBlank { "Answer on screen." })
            button("Read again") { speak() }
            button("End call") { StudyCalls.finish(this, id, "interrupted"); finish() }
        }
    }

    private fun answer() {
        if (StudyCalls.find(this, id)?.optString("status") != "ringing") return
        answered = true
        volumeControlStream = AudioManager.STREAM_VOICE_CALL
        StudyCalls.update(this, id) { it.put("status", "answered").put("answered_at", System.currentTimeMillis()) }
        StudyCalls.dismiss(this, id)
        render()
        if (ready) speak()
    }

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) tts?.setAudioAttributes(StudyCallAudio.attributes)
        if (answered && ready && started && !isFinishing) speak()
        else if (answered && !ready) message.append("\n\nSpeech unavailable. You can still choose an answer.")
    }

    private fun speak() {
        if (!ready || !answered || !started || isFinishing) return
        if (pendingVoicePermission) return
        acceptingAnswer = true
        stopReading()
        voice?.cancel()
        val row = StudyCalls.find(this, id) ?: return
        if (row.optString("status") != "answered") return
        if (callAudio?.state?.ready != true) {
            needsInitialReading = true
            callAudio?.start()
            return
        }
        val language = tts?.let { StudyCallSpeech.configure(it, this, row) }
        if (language == TextToSpeech.LANG_MISSING_DATA || language == TextToSpeech.LANG_NOT_SUPPORTED) {
            message.text = row.getString("question") + "\n\nInstall a voice for ${row.getString("language")} in Android speech settings."
            return
        }
        tts?.setAudioAttributes(StudyCallAudio.attributes)
        if (!requestSpeechFocus()) return
        val choices = row.getJSONArray("choices")
        // One utterance may exceed an engine's input limit: queue bounded
        // chunks, keeping the complete question and all numbered alternatives.
        val swedish = row.getString("language").startsWith("sv")
        val instruction = when {
            !voiceResponse || !voiceAvailable -> ""
            responseType == "text" -> if (swedish) ". Svara med ord eller en mening." else ". Say your answer."
            swedish -> ". Svara med numret eller alternativet."
            else -> ". Say the number or the alternative."
        }
        val prefix = if (retryFeedback.isBlank()) "" else if (swedish) "Försök igen. " else "Try again. "
        val spoken = prefix + row.getString("question") + ". " + (0 until choices.length()).joinToString(". ") {
            "${it + 1}. ${choices.getString(it)}"
        } + instruction
        needsInitialReading = false
        val chunks = spoken.chunked(3000)
        val batch = ++speechBatch
        autoListenUtterance = if (voiceResponse && voiceAvailable) "study-$id-$batch-${chunks.lastIndex}" else null
        lastReadUtterance = "study-$id-$batch-${chunks.lastIndex}"
        chunks.forEachIndexed { i, chunk ->
            if (tts?.speak(chunk, TextToSpeech.QUEUE_ADD, null, "study-$id-$batch-$i") == TextToSpeech.ERROR) {
                autoListenUtterance = null
                lastReadUtterance = null
                voiceStatus.text = "The question could not be read aloud. You can read it and answer on screen."
            }
        }
    }

    private fun isAnsweredAndResumed() = started && answered && !isFinishing &&
        StudyCalls.find(this, id)?.optString("status") == "answered"

    private fun stopReading() {
        speechBatch++
        autoListenUtterance = null
        lastReadUtterance = null
        tts?.stop()
    }

    private fun requestSpeechFocus(): Boolean {
        val audio = getSystemService(AudioManager::class.java) ?: return false
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            if (focus == null) focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(StudyCallAudio.attributes).setOnAudioFocusChangeListener(focusListener).build()
            audio.requestAudioFocus(focus!!)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(focusListener, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
        if (granted != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            needsInitialReading = true
            callAudio?.stop("Audio is busy. Tap Read again to resume.")
            return false
        }
        return true
    }

    private fun abandonSpeechFocus() {
        val audio = getSystemService(AudioManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 26) focus?.let { audio.abandonAudioFocusRequest(it) }
        else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(focusListener)
        }
    }

    private fun beginVoiceAnswer() {
        if (!voiceResponse || !isAnsweredAndResumed()) return
        stopReading()
        if (!voiceAvailable) {
            voiceStatus.text = "Speech recognition is unavailable. Tap an alternative to answer."
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            if (!pendingVoicePermission) {
                pendingVoicePermission = true
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MICROPHONE_REQUEST)
            }
            return
        }
        // Reading and listening never hold audio at the same time.
        abandonSpeechFocus()
        if (callAudio?.state?.ready != true) {
            listenOnAudioReady = true
            callAudio?.start()
            return
        }
        val row = StudyCalls.find(this, id) ?: return
        if (acceptingAnswer) voice?.start(row.getString("language"))
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grants)
        if (requestCode != MICROPHONE_REQUEST) return
        pendingVoicePermission = false
        if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            listenOnResume = true
            if (isAnsweredAndResumed()) { listenOnResume = false; beginVoiceAnswer() }
        } else if (::voiceStatus.isInitialized) {
            voiceStatus.text = "Microphone access was not granted. Tap an alternative, or allow microphone access in Android Settings."
        }
    }

    private fun completeChoice(index: Int, transcript: String? = null) {
        val row = StudyCalls.find(this, id) ?: return
        val choices = row.getJSONArray("choices")
        if (index !in 0 until choices.length()) return
        recordAttempt(choices.getString(index), index, if (transcript == null) "tap" else "voice", transcript)
    }

    private fun acceptSpeech(heard: List<String>) {
        val row = StudyCalls.find(this, id) ?: return
        if (responseType == "text") {
            val text = heard.firstOrNull { it.isNotBlank() }.orEmpty()
            recordAttempt(text, responseMode = "voice", transcript = text,
                reason = if (text.isBlank()) "no_input" else null)
        } else {
            val labels = row.getJSONArray("choices")
            val matched = StudyCallChoice.match(heard, (0 until labels.length()).map { labels.getString(it) },
                row.optDouble("match_threshold", StudyCallAnswer.DEFAULT_MATCH_THRESHOLD))
            if (matched != null) completeChoice(matched.index, matched.transcript)
            else recordAttempt(heard.firstOrNull().orEmpty(), responseMode = "voice",
                transcript = heard.firstOrNull(), reason = "unrecognized")
        }
    }

    private fun showVoiceStatus(text: String) {
        if (!::voiceStatus.isInitialized) return
        val row = StudyCalls.find(this, id)
        val used = row?.optJSONArray("attempts")?.length() ?: 0
        val limit = 1 + (row?.optInt("max_retries", StudyCallAnswer.DEFAULT_RETRIES) ?: StudyCallAnswer.DEFAULT_RETRIES)
        voiceStatus.text = "Attempt ${minOf(used + 1, limit)} of $limit.\n$text"
    }

    private fun recordAttempt(answer: String, choice: Int? = null, responseMode: String,
                              transcript: String? = null, reason: String? = null) {
        if (!acceptingAnswer || !isAnsweredAndResumed()) return
        acceptingAnswer = false
        stopReading()
        voice?.cancel()
        val result = try { StudyCalls.respond(this, id, answer, choice, responseMode, transcript, reason) }
            catch (_: Exception) {
                acceptingAnswer = true
                showVoiceStatus("Could not save your answer. Please try again.")
                return
            }
        if (result == null) { finish(); return }
        if (!result.retry) {
            showFinalFeedback(result.correct)
            return
        }
        retryFeedback = if (reason == null) "Not quite. Try again." else "The answer was not clear. Let's try again."
        needsInitialReading = true
        showVoiceStatus(retryFeedback)
        handler.postDelayed({
            if (isAnsweredAndResumed() && needsInitialReading) {
                acceptingAnswer = true
                render()
                speak()
            }
        }, 500)
    }

    private fun showFinalFeedback(correct: Boolean?) {
        finalFeedback = true
        while (body.childCount > 4) body.removeViewAt(4)
        voiceButton = null
        audioStatus = null; speakerButton = null
        val row = StudyCalls.find(this, id)
        val swedish = row?.optString("language")?.startsWith("sv") == true
        val feedback = when (correct) {
            true -> if (swedish) "Rätt svar." else "Correct."
            false -> if (swedish) "Inga försök kvar." else "No attempts left."
            null -> if (swedish) "Svaret har sparats." else "Answer saved."
        }
        message.text = feedback
        voiceStatus.visibility = View.VISIBLE
        voiceStatus.text = if (correct != false) row?.optString("answer").orEmpty() else "Your attempts have been saved."
        button("Close") { finish() }
        if (ready && started && callAudio?.state?.ready == true && requestSpeechFocus()) {
            tts?.setAudioAttributes(StudyCallAudio.attributes)
            tts?.speak(feedback, TextToSpeech.QUEUE_FLUSH, null, "result-$id")
        }
        handler.postDelayed({ if (!isFinishing) finish() }, 5000)
    }

    override fun onResume() {
        super.onResume()
        started = true
        if (finalFeedback) return
        if (answered) {
            volumeControlStream = AudioManager.STREAM_VOICE_CALL
            callAudio?.start()
        }
        if (needsInitialReading) acceptingAnswer = true
        if (answered && ready && needsInitialReading) speak()
        if (listenOnResume) { listenOnResume = false; beginVoiceAnswer() }
    }

    override fun onPause() {
        started = false
        listenOnResume = false
        listenOnAudioReady = false
        stopReading()
        voice?.cancel()
        abandonSpeechFocus(); callAudio?.stop()
        super.onPause()
    }

    override fun onStop() {
        started = false
        stopReading()
        voice?.cancel()
        abandonSpeechFocus(); callAudio?.stop()
        super.onStop()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        stopReading(); tts?.shutdown()
        voice?.cancel()
        abandonSpeechFocus(); callAudio?.stop()
        if (StudyCalls.visibleCallId == id) StudyCalls.visibleCallId = null
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("study_speaker", callAudio?.speakerPreferred == true)
        super.onSaveInstanceState(outState)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        endCall()
    }

    private fun endCall() {
        StudyCalls.finish(this, id, if (answered) "interrupted" else "declined")
        finish()
    }
}
