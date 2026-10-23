package org.satya.cupitor

import android.app.Activity
import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 35], manifest = Config.NONE)
class StudyCallsTest {
    private lateinit var context: Activity
    private fun args() = mapOf("title" to "Test", "question" to "Choose a word", "choices" to listOf("ett", "en"), "language" to "sv-SE")
    private fun store(vararg rows: JSONObject) {
        context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit()
            .putString("calls", JSONArray(rows.toList()).toString()).commit()
    }
    @Before fun setup() {
        context = Robolectric.buildActivity(Activity::class.java).setup().get()
        context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).edit().clear().commit()
        StudyCalls.visibleCallId = null
    }

    @Test fun validationRejectsMalformedChoicesAndTimesWithoutWritingAnything() {
        for (change in listOf(mapOf("choices" to listOf("one")), mapOf("choices" to listOf("a", 42)),
            mapOf("question" to " "), mapOf("language" to "bad-language-name"))) {
            try { StudyCalls.validate(args() + change, 1, true); fail("expected validation error") }
            catch (_: IllegalStateException) {}
        }
        try { StudyCalls.validate(args() + mapOf("when_ms" to 1000L), 1, false, 2000L); fail("past time") }
        catch (e: IllegalStateException) { assertEquals("bad_time", e.message) }
        assertTrue(StudyCalls.read(context).isEmpty())
    }

    @Test fun answerIsDurableAndDuplicateAnswerCannotOverwriteIt() {
        val row = StudyCalls.validate(args(), 7, true).put("status", "answered").put("answered_at", System.currentTimeMillis())
        val id = row.getString("id")
        StudyCalls.visibleCallId = id
        store(row)
        StudyCalls.finish(context, id, "completed", 1)
        StudyCalls.finish(context, id, "completed", 0)
        val saved = StudyCalls.find(context, id)!!
        assertEquals("completed", saved.getString("status"))
        assertEquals("en", saved.getString("choice"))
        assertEquals(1, saved.getInt("choice_index"))
        assertEquals(7, saved.getInt("profile_id"))
    }

    @Test fun declinedAndUnansweredCallsNeverAcquireAnAnswer() {
        val row = StudyCalls.validate(args(), 1, true)
        store(row)
        val id = row.getString("id")
        StudyCalls.finish(context, id, "completed", 0)
        assertEquals("scheduled", StudyCalls.find(context, id)!!.getString("status"))
        StudyCalls.finish(context, id, "declined")
        assertFalse(StudyCalls.find(context, id)!!.has("choice"))
    }

    @Test fun staleRingingAndProcessDeathAreReflectedInHistory() {
        val ringing = StudyCalls.validate(args(), 1, true).put("status", "ringing")
            .put("fired_at", System.currentTimeMillis() - StudyCalls.RING_MS - 1)
        val answered = StudyCalls.validate(args(), 1, true).put("status", "answered").put("answered_at", System.currentTimeMillis())
        store(ringing, answered)
        val states = StudyCalls.read(context).map { it.getString("status") }
        assertEquals(listOf("missed", "interrupted"), states)
    }

    @Test fun completingAnOldPendingCallKeepsTheNewAnswerWhenHistoryIsFull() {
        val active = StudyCalls.validate(args(), 1, true).put("status", "answered").put("answered_at", System.currentTimeMillis())
        val id = active.getString("id")
        StudyCalls.visibleCallId = id
        val history = (1..200).map {
            StudyCalls.validate(args(), 1, true).put("status", "declined").put("finished_at", it.toLong())
        }
        store(active, *history.toTypedArray())
        StudyCalls.finish(context, id, "completed", 0)
        assertEquals(200, StudyCalls.read(context).size)
        assertEquals("ett", StudyCalls.find(context, id)!!.getString("choice"))
    }

    @Test fun longQuestionActivityHasScrollableAlternativesAndBackDeclines() {
        val row = StudyCalls.validate(args() + mapOf("question" to "A long question. ".repeat(200)), 1, true)
            .put("status", "ringing").put("fired_at", System.currentTimeMillis())
        store(row)
        val screen = Robolectric.buildActivity(StudyCallActivity::class.java,
            Intent(context, StudyCallActivity::class.java).putExtra("id", row.getString("id"))).setup().get()
        assertNotNull(screen.findViewById<android.view.View>(android.R.id.content))
        screen.onBackPressed()
        assertEquals("declined", StudyCalls.find(context, row.getString("id"))!!.getString("status"))
    }
}
