package org.satya.cupitor

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale

/** Practice Log reminders share Study Calls' permissions, receiver and tap routing. */
object PracticeReminders {
    const val FIRE = "practice-reminder"
    const val TARGET_PREFIX = "practice-log:"
    private const val CHANNEL = "practice_log_reminders"
    private val languageKey = Regex("[a-z][a-z-]{0,39}")
    private val timePattern = Regex("([01][0-9]|2[0-3]):[0-5][0-9]")
    private val goalId = Regex("[a-f0-9-]{36}")
    private val datePattern = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")

    private fun store(context: Context) =
        context.getSharedPreferences("practice_log_reminders", Context.MODE_PRIVATE)

    private fun alarm(context: Context, key: String, whenMs: Long) = PendingIntent.getBroadcast(
        context, 0, Intent(context, StudyCallReceiver::class.java).setAction(FIRE)
            .setData(Uri.fromParts(FIRE, key, null))
            .putExtra("key", key).putExtra("when_ms", whenMs),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    @Synchronized fun save(context: Context, profile: Int, args: Map<*, *>) {
        val language = args["language"] as? String ?: error("bad_language")
        check(languageKey.matches(language)) { "bad_language" }
        val key = "$profile:$language"
        val slots = args["slots"] as? List<*> ?: error("bad_slots")
        val goals = args["goals"] as? List<*> ?: error("bad_goals")
        check(slots.size <= 48) { "too_many_reminders" }
        val enabled = args["enabled"] == true
        val checkedSlots = slots.map { raw ->
            val slot = raw as? Map<*, *> ?: error("bad_slot")
            val time = slot["time"] as? String ?: error("bad_time")
            val days = (slot["days"] as? List<*>)?.map { (it as? Int) ?: error("bad_day") }
                ?: error("bad_day")
            check(timePattern.matches(time) && days.isNotEmpty() && days.all { it in 1..7 }) { "bad_slot" }
            JSONObject().put("time", time).put("days", JSONArray(days.distinct()))
        }
        val checkedGoals = goals.map { raw ->
            val goal = raw as? Map<*, *> ?: error("bad_goal")
            val id = goal["id"] as? String ?: error("bad_goal")
            val title = goal["title"] as? String ?: error("bad_goal")
            val date = goal["last_update"] as? String ?: error("bad_goal")
            check(goalId.matches(id) && title.length in 1..120 &&
                (date.isEmpty() || datePattern.matches(date))) { "bad_goal" }
            JSONObject().put("id", id).put("title", title).put("last_update", date)
        }
        val config = JSONObject().put("slots", JSONArray(checkedSlots)).put("goals", JSONArray(checkedGoals))
        val prefs = store(context)
        val editor = prefs.edit()
        if (enabled) editor.putString(key, config.toString()) else editor.remove(key)
        check(editor.commit()) { "storage_error" }
        arm(context, key, if (enabled) config else null)
    }

    @Synchronized fun rearm(context: Context) {
        store(context).all.forEach { (key, value) ->
            if (value is String) arm(context, key, JSONObject(value))
        }
    }

    private fun arm(context: Context, key: String, config: JSONObject?) {
        val alarms = requireNotNull(context.getSystemService(AlarmManager::class.java))
        val next = if (config != null && config.getJSONArray("goals").length() > 0)
            nextTime(config.getJSONArray("slots"), Calendar.getInstance()) else null
        val pending = alarm(context, key, next ?: 0L)
        if (next == null) {
            alarms.cancel(pending)
        } else {
            try {
                if (StudyCalls.exactAllowed(context)) {
                    alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending)
                } else {
                    alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending)
                }
            } catch (_: SecurityException) {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending)
            }
        }
    }

    internal fun nextTime(slots: JSONArray, now: Calendar): Long? {
        for (offset in 0..7) {
            val day = (now.clone() as Calendar).apply { add(Calendar.DATE, offset) }
            val weekday = (day.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
            val candidates = (0 until slots.length()).mapNotNull { index ->
                val slot = slots.getJSONObject(index)
                val days = slot.getJSONArray("days")
                if ((0 until days.length()).none { days.getInt(it) == weekday }) return@mapNotNull null
                val parts = slot.getString("time").split(':')
                (day.clone() as Calendar).apply {
                    set(Calendar.HOUR_OF_DAY, parts[0].toInt())
                    set(Calendar.MINUTE, parts[1].toInt())
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }.timeInMillis.takeIf { it > now.timeInMillis }
            }
            candidates.minOrNull()?.let { return it }
        }
        return null
    }

    private fun localDate(day: Calendar): String = String.format(
        Locale.ROOT, "%04d-%02d-%02d", day.get(Calendar.YEAR),
        day.get(Calendar.MONTH) + 1, day.get(Calendar.DAY_OF_MONTH),
    )

    @Synchronized fun deliver(context: Context, intent: Intent) {
        val key = intent.getStringExtra("key") ?: return
        val raw = store(context).getString(key, null) ?: return
        val config = JSONObject(raw)
        val now = Calendar.getInstance()
        val timestamp = intent.getLongExtra("when_ms", 0)
        val scheduled = Calendar.getInstance().apply { timeInMillis = timestamp }
        arm(context, key, config)
        val today = localDate(now)
        if (timestamp <= 0 || timestamp > now.timeInMillis || localDate(scheduled) != today ||
            StudyCalls.permission(context) != "granted") return

        val goals = config.getJSONArray("goals")
        val due = (0 until goals.length()).map(goals::getJSONObject)
            .filter { it.getString("last_update") != today }
        if (due.isEmpty()) return
        val (profile, language) = key.split(':', limit = 2)
        val goal = due.singleOrNull()
        val target = JSONObject().put("profile_id", profile.toInt())
            .put("id", "$TARGET_PREFIX$language:${goal?.getString("id").orEmpty()}")
        val tap = PendingIntent.getActivity(context, 0, StudyCallHistory.intent(context, target),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notifications = requireNotNull(context.getSystemService(NotificationManager::class.java))
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(NotificationChannel(
                CHANNEL, "Practice Log reminders", NotificationManager.IMPORTANCE_DEFAULT,
            ))
            Notification.Builder(context, CHANNEL)
        } else {
            Notification.Builder(context).setDefaults(Notification.DEFAULT_ALL)
        }
        val message = if (goal != null) "Time to update ${goal.getString("title")}."
            else "Time to update ${due.size} practice goals."
        notifications.notify(key, 1, builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Practice Log").setContentText(message)
            .setStyle(Notification.BigTextStyle().bigText(message))
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(tap).setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, "Update progress", tap).build()).build())
    }
}
