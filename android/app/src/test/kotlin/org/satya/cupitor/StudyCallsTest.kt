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

    private fun playlistArgs(due: Long = System.currentTimeMillis() + 60_000) = args() + mapOf(
        "profile_id" to 1, "notif_id" to 123, "due_at" to due, "when_ms" to due,
        "playlist_key" to "words", "item_external_id" to "card:one")

    @Test fun playlistFireIsIdempotentEvenAfterAnswering() {
        val args = playlistArgs()
        val id = StudyCalls.deliverPlaylist(context, args)
        assertEquals(id, StudyCalls.deliverPlaylist(context, args))
        StudyCalls.finish(context, id, "declined")
        assertEquals(id, StudyCalls.deliverPlaylist(context, args + mapOf("immediate" to true)))
        assertEquals(1, StudyCalls.read(context).size)
        assertEquals("declined", StudyCalls.find(context, id)!!.getString("status"))
    }

    @Test fun rearmPreservesOneOffCallsAndQueuedDueCalls() {
        val future = StudyCalls.deliverPlaylist(context, playlistArgs())
        StudyCalls.visibleCallId = "busy"
        val queued = StudyCalls.deliverPlaylist(context, playlistArgs(System.currentTimeMillis() - 1000) +
            mapOf("immediate" to true))
        val oneOff = StudyCalls.validate(args(), 1, true)
        store(*StudyCalls.read(context).toTypedArray(), oneOff)
        StudyCalls.cancelPlaylistScheduled(context)
        assertNull(StudyCalls.find(context, future))
        assertNotNull(StudyCalls.find(context, queued))
        assertNotNull(StudyCalls.find(context, oneOff.getString("id")))
        StudyCalls.retainPlaylistItems(context, emptySet())
        assertEquals("cancelled", StudyCalls.find(context, queued)!!.getString("status"))
        assertEquals("scheduled", StudyCalls.find(context, oneOff.getString("id"))!!.getString("status"))
    }

    @Test fun overlappingPlaylistCallsQueueInsteadOfBeingMarkedMissed() {
        StudyCalls.visibleCallId = "another-call"
        val due = System.currentTimeMillis()
        val id = StudyCalls.deliverPlaylist(context, playlistArgs(due) + mapOf("immediate" to true))
        val row = StudyCalls.find(context, id)!!
        assertEquals("scheduled", row.getString("status"))
        assertTrue(row.getLong("when_ms") > due)
        assertEquals(due, row.getLong("due_at"))
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

    @Test fun wrongThenCorrectChoiceSavesBothAttemptsAndStopsImmediately() {
        val row = StudyCalls.validate(args() + mapOf("correct_choice_index" to 1), 1, true)
            .put("status", "answered").put("answered_at", System.currentTimeMillis())
        val id = row.getString("id")
        StudyCalls.visibleCallId = id
        store(row)
        val wrong = StudyCalls.respond(context, id, "ett", 0, "voice", "ett")!!
        assertFalse(wrong.correct!!); assertTrue(wrong.retry)
        assertEquals(1, wrong.attempts); assertEquals(4, wrong.maxAttempts)
        val right = StudyCalls.respond(context, id, "en", 1, "voice", "en")!!
        assertTrue(right.correct!!); assertFalse(right.retry)
        assertNull(StudyCalls.respond(context, id, "ett", 0))
        val saved = StudyCalls.find(context, id)!!
        assertEquals("completed", saved.getString("status"))
        assertEquals(2, saved.getJSONArray("attempts").length())
        assertEquals("voice", saved.getString("response_mode"))
        assertEquals("en", saved.getString("spoken_response"))
    }

    @Test fun retryBudgetAlsoBoundsSilenceAndUnrecognizedSpeech() {
        val row = StudyCalls.validate(args() + mapOf("correct_choice_index" to 1), 1, true)
            .put("status", "answered").put("answered_at", System.currentTimeMillis())
        val id = row.getString("id")
        StudyCalls.visibleCallId = id; store(row)
        for (i in 1..4) {
            val result = StudyCalls.respond(context, id, "", responseMode = "voice", reason = "no_input")!!
            assertEquals(i < 4, result.retry)
        }
        assertEquals("failed", StudyCalls.find(context, id)!!.getString("status"))
        assertNull(StudyCalls.respond(context, id, "en", 1))
    }

    @Test fun freeFormVoiceAnswersAreFuzzyMarkedAndPersistedWithoutAlternatives() {
        val row = StudyCalls.validate(args() + mapOf("response_type" to "text", "accepted_answers" to listOf("Stockholm")), 1, true)
            .put("status", "answered").put("answered_at", System.currentTimeMillis())
        val id = row.getString("id")
        StudyCalls.visibleCallId = id; store(row)
        assertEquals(0, row.getJSONArray("choices").length())
        val result = StudyCalls.respond(context, id, "Stockholn", responseMode = "voice", spokenResponse = "Stockholn")!!
        assertTrue(result.correct!!)
        val saved = StudyCalls.find(context, id)!!
        assertEquals("Stockholn", saved.getString("answer"))
        assertFalse(saved.has("choice_index"))
    }

    @Test fun invalidRetryAndMarkingConfigurationIsRejectedBeforeCreatingACall() {
        for (bad in listOf(mapOf("max_retries" to -1), mapOf("max_retries" to 1.5), mapOf("max_retries" to 11),
            mapOf("correct_choice_index" to 8), mapOf("match_threshold" to Double.NaN),
            mapOf("voice_response" to "true"), mapOf("response_type" to "text", "accepted_answers" to emptyList<String>()))) {
            try { StudyCalls.validate(args() + bad, 1, true); fail("expected validation failure") }
            catch (_: IllegalStateException) {}
        }
    }
}
