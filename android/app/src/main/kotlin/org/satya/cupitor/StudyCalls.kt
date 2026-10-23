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
import android.media.AudioAttributes
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
import android.view.WindowManager
import android.widget.Button
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
    private const val PERMISSION_REQUEST = 4301
    private var permissionReply: MethodChannel.Result? = null
    var visibleCallId: String? = null
    private val terminal = setOf("completed", "declined", "missed", "cancelled", "interrupted")

    fun install(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "cupitor/study_calls").setMethodCallHandler { call, reply ->
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val profile = (args["profile_id"] as? Number)?.toInt() ?: 1
                when (call.method) {
                    "getCapabilities" -> reply.success(mapOf(
                        "supported" to true, "permission" to permission(activity),
                        "full_screen" to fullScreenAllowed(activity),
                        "exact_alarms" to exactAllowed(activity), "speech_input" to false,
                    ))
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
                        check(read(activity).count { !terminal.contains(it.optString("status")) } < 50) { "too_many_calls" }
                        mutate(activity) { it.add(data) }
                        try {
                            if (call.method == "callNow") {
                                fire(activity, data.getString("id"))
                                activity.startActivity(screenIntent(activity, data.getString("id"), false))
                            } else arm(activity, data)
                        } catch (e: Exception) {
                            update(activity, data.getString("id")) { it.put("status", "cancelled") }
                            dismiss(activity, data.getString("id"))
                            throw e
                        }
                        reply.success(mapOf("id" to data.getString("id"), "exact" to exactAllowed(activity)))
                    }
                    "cancel" -> {
                        val id = args["id"] as? String ?: error("bad_payload")
                        val row = read(activity).find { it.optString("id") == id && it.optInt("profile_id") == profile }
                            ?: error("unknown_call")
                        if (!terminal.contains(row.optString("status"))) {
                            update(activity, id) { it.put("status", "cancelled").put("finished_at", System.currentTimeMillis()) }
                            dismiss(activity, id)
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
        val choices = args["choices"] as? List<*> ?: error("bad_payload")
        check(choices.size in 2..9) { "bad_payload" }
        val labels = choices.map {
            val s = (it as? String)?.trim() ?: error("bad_payload")
            check(s.isNotEmpty() && s.length <= 200) { "bad_payload" }; s
        }
        val language = (args["language"] as? String) ?: "sv-SE"
        check(language.matches(Regex("[a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?"))) { "bad_payload" }
        val whenMs = if (immediate) now else (args["when_ms"] as? Number)?.toLong() ?: error("bad_payload")
        check(immediate || (whenMs > now && whenMs <= now + 366L * 24 * 60 * 60 * 1000)) { "bad_time" }
        return JSONObject().put("id", UUID.randomUUID().toString()).put("profile_id", profile)
            .put("title", title).put("question", question).put("choices", JSONArray(labels))
            .put("language", language).put("when_ms", whenMs).put("created_at", now)
            .put("status", "scheduled")
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
        if (changed) save(context, rows)
        return rows
    }

    private fun save(context: Context, rows: List<JSONObject>) {
        val active = rows.filter { !terminal.contains(it.optString("status")) }
        val history = rows.filter { terminal.contains(it.optString("status")) }
            .sortedBy { it.optLong("finished_at", it.optLong("created_at")) }.takeLast(200)
        check(context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit()
            .putString("calls", JSONArray(active + history).toString()).commit()) { "storage_error" }
    }

    @Synchronized private fun mutate(context: Context, fn: (MutableList<JSONObject>) -> Unit) {
        val rows = read(context); fn(rows); save(context, rows)
    }
    fun find(context: Context, id: String) = read(context).find { it.optString("id") == id }
    fun update(context: Context, id: String, fn: (JSONObject) -> Unit) = mutate(context) { rows ->
        rows.find { it.optString("id") == id }?.let(fn)
    }
    private fun asMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
        when (val value = json.get(key)) {
            is JSONArray -> (0 until value.length()).map { value.get(it) }
            JSONObject.NULL -> null
            else -> value
        }
    }

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

    fun finish(context: Context, id: String, status: String, choice: Int? = null) {
        var settled = false
        update(context, id) {
            settled = terminal.contains(it.optString("status"))
            if (!terminal.contains(it.optString("status"))) {
                if (choice != null && (it.optString("status") != "answered" || choice !in 0 until it.getJSONArray("choices").length())) return@update
                it.put("status", status).put("finished_at", System.currentTimeMillis())
                if (choice != null) it.put("choice_index", choice).put("choice", it.getJSONArray("choices").getString(choice))
                settled = true
            }
        }
        if (settled) dismiss(context, id)
    }

    fun fire(context: Context, id: String) {
        val row = find(context, id) ?: return
        if (row.optString("status") != "scheduled") return
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
                StudyCalls.read(context).filter { it.optString("status") == "scheduled" }.forEach {
                    try { StudyCalls.arm(context, it) } catch (_: Exception) {}
                }
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

/** Scrollable native UI works while Flutter and the page are absent. Only an
 * explicit Answer reveals/speaks the question. No microphone permission needed. */
class StudyCallActivity : Activity(), TextToSpeech.OnInitListener {
    private var id = ""
    private var tts: TextToSpeech? = null
    private var ready = false
    private var answered = false
    private var started = false
    private var needsInitialReading = true
    private var focus: AudioFocusRequest? = null
    private lateinit var body: LinearLayout
    private lateinit var message: TextView
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
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
        render()
        tts = TextToSpeech(this, this)
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
        while (body.childCount > 3) body.removeViewAt(3)
        val row = StudyCalls.find(this, id) ?: return
        if (!answered) {
            message.text = "Incoming study call"
            button("Answer") { answer() }
            button("Decline") { StudyCalls.finish(this, id, "declined"); finish() }
        } else {
            message.text = row.getString("question")
            val choices = row.getJSONArray("choices")
            for (i in 0 until choices.length()) button("${i + 1}. ${choices.getString(i)}") {
                StudyCalls.finish(this, id, "completed", i); tts?.stop(); finish()
            }
            button("Read again") { speak() }
            button("End call") { StudyCalls.finish(this, id, "interrupted"); finish() }
        }
    }

    private fun answer() {
        if (StudyCalls.find(this, id)?.optString("status") != "ringing") return
        answered = true
        StudyCalls.update(this, id) { it.put("status", "answered").put("answered_at", System.currentTimeMillis()) }
        StudyCalls.dismiss(this, id)
        render()
        if (ready) speak()
    }

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (answered && ready && started && !isFinishing) speak()
        else if (answered && !ready) message.append("\n\nSpeech unavailable. You can still choose an answer.")
    }

    private fun speak() {
        if (!ready || !answered || !started || isFinishing) return
        val row = StudyCalls.find(this, id) ?: return
        if (row.optString("status") != "answered") return
        val language = tts?.setLanguage(Locale.forLanguageTag(row.getString("language")))
        if (language == TextToSpeech.LANG_MISSING_DATA || language == TextToSpeech.LANG_NOT_SUPPORTED) {
            message.text = row.getString("question") + "\n\nInstall a voice for ${row.getString("language")} in Android speech settings."
            return
        }
        val audio = getSystemService(AudioManager::class.java) ?: return
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        tts?.setAudioAttributes(attributes)
        if (Build.VERSION.SDK_INT >= 26) {
            if (focus == null) focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener { if (it < 0) tts?.stop() }.build()
            if (audio.requestAudioFocus(focus!!) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return
        }
        val choices = row.getJSONArray("choices")
        // One utterance may exceed an engine's input limit: queue bounded
        // chunks, keeping the complete question and all numbered alternatives.
        val spoken = row.getString("question") + ". " + (0 until choices.length()).joinToString(". ") {
            "${it + 1}. ${choices.getString(it)}"
        }
        tts?.stop()
        needsInitialReading = false
        spoken.chunked(3000).forEachIndexed { i, chunk ->
            tts?.speak(chunk, TextToSpeech.QUEUE_ADD, null, "study-$id-$i")
        }
    }

    override fun onResume() {
        super.onResume()
        started = true
        if (answered && ready && needsInitialReading) speak()
    }

    override fun onPause() {
        started = false
        tts?.stop()
        super.onPause()
    }

    override fun onStop() {
        started = false
        tts?.stop()
        if (Build.VERSION.SDK_INT >= 26) focus?.let { getSystemService(AudioManager::class.java)?.abandonAudioFocusRequest(it) }
        super.onStop()
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        tts?.stop(); tts?.shutdown()
        if (StudyCalls.visibleCallId == id) StudyCalls.visibleCallId = null
        super.onDestroy()
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
