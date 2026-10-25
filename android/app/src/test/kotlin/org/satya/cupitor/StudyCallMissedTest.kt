package org.satya.cupitor

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 35], manifest = Config.NONE)
class StudyCallMissedTest {
    private lateinit var context: android.app.Application
    private val notifications get() = context.getSystemService(NotificationManager::class.java)
    private fun row(profile: Int = 7) = StudyCalls.validate(mapOf("title" to "Swedish vocabulary", "question" to "Which article?",
        "choices" to listOf("ett", "en"), "correct_choice_index" to 1, "language" to "sv-SE"), profile, true)
    private fun store(vararg rows: JSONObject) {
        context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit().putString("calls", JSONArray(rows.toList()).toString()).commit()
    }
    private fun missed(id: String) = notifications.activeNotifications.singleOrNull { it.tag == id && it.id == 2 }?.notification

    @Before fun reset() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("study_call_history", Context.MODE_PRIVATE).edit().clear().commit()
        notifications.cancelAll()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        StudyCalls.visibleCallId = null
    }

    @Test fun expiredRingLeavesOrdinaryMissedNotificationWithAnExactHistoryTarget() {
        val call = row().put("status", "ringing").put("fired_at", System.currentTimeMillis() - StudyCalls.RING_MS - 1)
        val id = call.getString("id")
        store(call)
        StudyCalls.read(context)
        val notification = missed(id)!!
        assertEquals("missed", StudyCalls.find(context, id)!!.getString("status"))
        assertEquals("Missed study call", notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("Swedish vocabulary", notification.extras.getString(Notification.EXTRA_TEXT))
        assertTrue(notification.flags and Notification.FLAG_AUTO_CANCEL != 0)
        assertEquals(0, notification.flags and (Notification.FLAG_INSISTENT or Notification.FLAG_ONGOING_EVENT))
        assertNull(notification.fullScreenIntent)
        assertTrue(notification.actions.isNullOrEmpty())
        assertEquals(if (Build.VERSION.SDK_INT >= 31) Notification.CATEGORY_MISSED_CALL else Notification.CATEGORY_CALL, notification.category)
        if (Build.VERSION.SDK_INT >= 26) assertEquals(StudyCalls.MISSED_CHANNEL, notification.channelId)
        val intent = shadowOf(notification.contentIntent).savedIntent
        assertEquals(MainActivity::class.java.name, intent.component!!.className)
        assertNull(intent.data) // Flutter must start at its normal route.
        StudyCallHistory.capture(context, intent)
        val target = StudyCallHistory.takePendingOpen(context)!!
        assertEquals(id, target["id"])
        assertEquals(7, target["profile_id"])
        assertNull(StudyCallHistory.takePendingOpen(context))
        StudyCallHistory.capture(context, intent) // activity/engine recreation
        assertNull(StudyCallHistory.takePendingOpen(context))
    }

    @Test fun aDismissedMissedNotificationDoesNotReappearOnRefreshOrDuplicateExpiry() {
        val call = row()
        val id = call.getString("id")
        store(call)
        StudyCalls.finish(context, id, "missed")
        assertNotNull(missed(id))
        notifications.cancel(id, 2)
        StudyCalls.read(context)
        StudyCalls.finish(context, id, "missed")
        StudyCallReceiver().onReceive(context, Intent().setAction("expire").putExtra("id", id))
        assertNull(missed(id))
    }

    @Test fun callsThatOverlapOrFireTooLateAreMissedWithoutReplacingAnActiveCall() {
        val call = row()
        val id = call.getString("id")
        store(call)
        StudyCalls.visibleCallId = "another-active-call"
        StudyCalls.fire(context, id)
        assertNotNull(missed(id))
        assertEquals("another-active-call", StudyCalls.visibleCallId)
        StudyCalls.visibleCallId = null
        val late = row().put("when_ms", System.currentTimeMillis() - 6 * 60_000)
        store(call, late)
        StudyCalls.fire(context, late.getString("id"))
        assertNotNull(missed(late.getString("id")))
    }

    @Test fun differentMissedCallsKeepDistinctTapTargetsAndTheLatestTapWins() {
        val first = row(7); val second = row(9)
        store(first, second)
        StudyCalls.finish(context, first.getString("id"), "missed")
        StudyCalls.finish(context, second.getString("id"), "missed")
        val one = missed(first.getString("id"))!!.contentIntent
        val two = missed(second.getString("id"))!!.contentIntent
        assertNotEquals(one, two)
        StudyCallHistory.capture(context, shadowOf(one).savedIntent)
        StudyCallHistory.capture(context, shadowOf(two).savedIntent)
        val target = StudyCallHistory.takePendingOpen(context)!!
        assertEquals(second.getString("id"), target["id"])
        assertEquals(9, target["profile_id"])
    }

    @Test fun decliningCancellingAndAnsweringDoNotCreateMissedNotifications() {
        for (status in listOf("declined", "cancelled", "completed", "interrupted")) {
            val call = row(); store(call)
            StudyCalls.finish(context, call.getString("id"), status)
            assertNull(missed(call.getString("id")))
        }
    }

    @Test fun historyEvictionRemovesTheCorrespondingMissedNotification() {
        val old = row(); val id = old.getString("id"); store(old)
        StudyCalls.finish(context, id, "missed")
        assertNotNull(missed(id))
        val finished = StudyCalls.find(context, id)!!
        val newer = (1..100).map { row().put("status", "completed").put("finished_at", System.currentTimeMillis() + it) }
        store(finished, *newer.toTypedArray())
        assertEquals(100, StudyCalls.read(context).size)
        assertNull(missed(id))
    }

    @Test fun normalLaunchAndMalformedTargetsCannotOpenHistory() {
        StudyCallHistory.capture(context, Intent(Intent.ACTION_MAIN))
        StudyCallHistory.capture(context, Intent().setAction(StudyCallHistory.ACTION + "/").putExtra("profile_id", 7))
        StudyCallHistory.capture(context, Intent().setAction(StudyCallHistory.ACTION + "/id").putExtra("profile_id", -1))
        assertNull(StudyCallHistory.takePendingOpen(context))
    }
}
