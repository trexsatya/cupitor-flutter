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
        assertEquals(100, StudyCalls.read(context).size)
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
    private fun futureArgs() = args() + mapOf("when_ms" to System.currentTimeMillis() + 3600000L, "correct_choice_index" to 1)
    private fun expectError(message: String, action: () -> Unit) {
        try { action(); fail("expected $message") } catch (e: IllegalStateException) { assertEquals(message, e.message) }
    }

    @Test fun batchValidatesEverythingAndRollsBackWhenArmingFails() {
        val armed = mutableListOf<String>()
        expectError("bad_payload") {
            StudyCalls.scheduleBatch(context, listOf(futureArgs(), futureArgs() + mapOf("choices" to listOf("one"))), 7) { _, row -> armed.add(row.getString("id")) }
        }
        assertTrue(StudyCalls.read(context).isEmpty()); assertTrue(armed.isEmpty())
        expectError("alarm_failed") {
            StudyCalls.scheduleBatch(context, listOf(futureArgs(), futureArgs()), 7) { _, _ -> error("alarm_failed") }
        }
        assertTrue(StudyCalls.read(context).isEmpty())
        val ids = StudyCalls.scheduleBatch(context, listOf(futureArgs() + mapOf("profile_id" to 99), futureArgs() + mapOf("enabled" to false)), 7) { _, row -> armed.add(row.getString("id")) }
        assertEquals(2, ids.size); assertEquals(listOf(ids[0]), armed)
        assertEquals("disabled", StudyCalls.find(context, ids[1])!!.getString("status"))
        assertTrue(StudyCalls.read(context).all { it.getInt("profile_id") == 7 })
        expectError("too_many_calls") { StudyCalls.scheduleBatch(context, List(49) { futureArgs() }, 7) { _, _ -> } }
        assertEquals(2, StudyCalls.read(context).size)
    }

    @Test fun editingPreservesIdentityAndRejectsOtherProfilesAndStartedCalls() {
        val id = StudyCalls.scheduleBatch(context, listOf(futureArgs()), 7) { _, _ -> }.single()
        val created = StudyCalls.find(context, id)!!.getLong("created_at")
        expectError("unknown_call") { StudyCalls.editScheduled(context, futureArgs() + mapOf("id" to id), 8) { _, _ -> } }
        expectError("bad_payload") { StudyCalls.editScheduled(context, futureArgs() + mapOf("id" to id, "question" to ""), 7) { _, _ -> } }
        assertEquals("Choose a word", StudyCalls.find(context, id)!!.getString("question"))
        StudyCalls.editScheduled(context, futureArgs() + mapOf("id" to id, "question" to "Edited", "enabled" to false), 7) { _, _ -> fail("disabled call armed") }
        val saved = StudyCalls.find(context, id)!!
        assertEquals(created, saved.getLong("created_at")); assertEquals("Edited", saved.getString("question"))
        assertEquals("disabled", saved.getString("status"))
        expectError("alarm_failed") { StudyCalls.editScheduled(context, futureArgs() + mapOf("id" to id), 7) { _, _ -> error("alarm_failed") } }
        assertEquals("Edited", StudyCalls.find(context, id)!!.getString("question"))
        StudyCalls.update(context, id) { it.put("status", "ringing").put("fired_at", System.currentTimeMillis()) }
        expectError("not_scheduled") { StudyCalls.editScheduled(context, futureArgs() + mapOf("id" to id), 7) { _, _ -> } }
        expectError("not_scheduled") { StudyCalls.removePending(context, id, 7) }
    }

    @Test fun pendingEnableDisableAndRemovalAreDurableAndProfileScoped() {
        val id = StudyCalls.scheduleBatch(context, listOf(futureArgs()), 7) { _, _ -> }.single()
        expectError("unknown_call") { StudyCalls.setEnabled(context, id, 8, false) }
        expectError("unknown_call") { StudyCalls.removePending(context, id, 8) }
        StudyCalls.setEnabled(context, id, 7, false)
        assertEquals("disabled", StudyCalls.find(context, id)!!.getString("status"))
        StudyCalls.setEnabled(context, id, 7, true)
        assertEquals("scheduled", StudyCalls.find(context, id)!!.getString("status"))
        StudyCalls.setEnabled(context, id, 7, false)
        StudyCalls.update(context, id) { it.put("when_ms", 1L) }
        expectError("bad_time") { StudyCalls.setEnabled(context, id, 7, true) }
        StudyCalls.removePending(context, id, 7)
        assertNull(StudyCalls.find(context, id))
    }

    @Test fun upgradeTrimsHistoryTo100WithoutRemovingPendingAndRetiresPlaylistCalls() {
        val pending = StudyCalls.validate(futureArgs() + mapOf("enabled" to false), 1, false)
        val obsolete = StudyCalls.validate(futureArgs(), 1, false).put("notif_id", 123)
        val history = (1..200).map { StudyCalls.validate(args(), 1, true).put("status", "declined").put("finished_at", it.toLong()) }
        store(pending, obsolete, *history.toTypedArray())
        assertEquals(102, StudyCalls.read(context).size)
        assertEquals(102, JSONArray(context.getSharedPreferences("study_calls", Context.MODE_PRIVATE).getString("calls", "[]")).length())
        StudyCalls.cancelObsoletePlaylistCalls(context)
        assertEquals("cancelled", StudyCalls.find(context, obsolete.getString("id"))!!.getString("status"))
        assertEquals("disabled", StudyCalls.find(context, pending.getString("id"))!!.getString("status"))
        assertEquals(101, StudyCalls.read(context).size)
    }

    @Test fun staleAlarmAfterReschedulingCannotRingEarly() {
        val id = StudyCalls.scheduleBatch(context, listOf(futureArgs()), 7) { _, _ -> }.single()
        StudyCalls.editScheduled(context, futureArgs() + mapOf("id" to id, "when_ms" to System.currentTimeMillis() + 7200000L), 7) { _, _ -> }
        StudyCalls.fire(context, id)
        assertEquals("scheduled", StudyCalls.find(context, id)!!.getString("status"))
        StudyCalls.setEnabled(context, id, 7, false)
        StudyCalls.fire(context, id)
        assertEquals("disabled", StudyCalls.find(context, id)!!.getString("status"))
    }

    @Test fun configuredLimitIsDurableGlobalAndLoweringItDoesNotDeleteCalls() {
        assertEquals(50, StudyCalls.pendingLimit(context))
        for (bad in listOf<Any?>(null, "500", 0, -1, 1.5, 5001, Double.NaN)) {
            expectError("bad_limit") { StudyCalls.setPendingLimit(context, bad) }
        }
        StudyCalls.setPendingLimit(context, 500)
        assertEquals(500, StudyCalls.pendingLimit(context))
        val ids = StudyCalls.scheduleBatch(context, List(120) { futureArgs() + mapOf("enabled" to false) }, 7) { _, _ -> fail("disabled call armed") }
        assertEquals(120, ids.size)
        StudyCalls.setPendingLimit(context, 100)
        assertEquals(120, StudyCalls.read(context).size)
        expectError("too_many_calls") { StudyCalls.scheduleBatch(context, listOf(futureArgs()), 8) { _, _ -> } }
    }

    @Test fun rollingAlarmPlanOnlyArms50EarliestEnabledCallsAndRefills() {
        StudyCalls.setPendingLimit(context, 200)
        val start = System.currentTimeMillis() + 3600000L
        val armed = mutableListOf<String>()
        val ids = StudyCalls.scheduleBatch(context, (0 until 120).map { futureArgs() + mapOf("when_ms" to start + it * 60000L) }, 7) { _, row -> armed.add(row.getString("id")) }
        assertEquals(ids.take(50), armed)
        assertEquals(120, StudyCalls.read(context).size)
        StudyCalls.setEnabled(context, ids[0], 7, false)
        assertEquals(ids.subList(1, 51), StudyCalls.alarmPlan(context).map { it.getString("id") })
        StudyCalls.removePending(context, ids[1], 7)
        assertEquals(ids.subList(2, 52), StudyCalls.alarmPlan(context).map { it.getString("id") })
        StudyCalls.finish(context, ids[2], "cancelled")
        assertEquals(ids.subList(3, 53), StudyCalls.alarmPlan(context).map { it.getString("id") })
    }

    @Test fun speechDefaultsAndOverridesAreValidatedWithoutPartialSettingsWrites() {
        StudyCalls.setSettings(context, mapOf("pending_limit" to 200, "voice_name" to "sv-test", "speech_rate" to 0.75))
        assertEquals("sv-test", StudyCallSpeech.defaults(context)["voice_name"])
        assertEquals(0.75, StudyCallSpeech.defaults(context)["speech_rate"])
        for (bad in listOf(mapOf("speech_rate" to 0.1), mapOf("speech_rate" to Double.NaN), mapOf("voice_name" to 3))) {
            expectError("bad_voice") { StudyCalls.setSettings(context, bad + mapOf("pending_limit" to 300)) }
            assertEquals(200, StudyCalls.pendingLimit(context))
        }
        val call = StudyCalls.validate(futureArgs() + mapOf("voice_name" to "", "speech_rate" to 1.25), 7, false)
        assertEquals("", call.getString("voice_name")); assertEquals(1.25, call.getDouble("speech_rate"), 0.001)
        val voice = android.speech.tts.Voice("sv-test", java.util.Locale.forLanguageTag("sv-SE"), 400, 200, false, emptySet())
        val missing = android.speech.tts.Voice("sv-missing", java.util.Locale.forLanguageTag("sv-SE"), 400, 200, false, setOf(android.speech.tts.TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED))
        val options = StudyCallSpeech.options(setOf(voice, missing))
        assertEquals(1, options.size); assertEquals("sv-test", options.single()["name"])
    }

}
