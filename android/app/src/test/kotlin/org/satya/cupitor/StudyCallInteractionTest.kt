package org.satya.cupitor

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.ShadowAudioTrack
import org.robolectric.shadows.ShadowTextToSpeech
import org.robolectric.util.ReflectionHelpers
import java.time.Duration
import java.util.Locale

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class StudyCallInteractionTest {
    private lateinit var context: Activity
    private fun args() = mapOf("title" to "Words", "question" to "Säg huvudstaden", "response_type" to "text",
        "accepted_answers" to listOf("Stockholm"), "language" to "sv-SE", "voice_response" to false,
        "repetition_pause_seconds" to 2.0, "speech_rate" to 0.75)
    private fun store(vararg rows: JSONObject) {
        context.getSharedPreferences("study_calls", 0).edit().putString("calls", JSONArray(rows.toList()).toString()).commit()
    }
    @Before fun setup() {
        context = Robolectric.buildActivity(Activity::class.java).setup().get()
        context.getSharedPreferences("study_calls", 0).edit().clear().commit()
        StudyCalls.visibleCallId = null
        shadowOf(context.application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
    }
    private fun idle(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun device(): AudioDeviceInfo = AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE).build().also {
        val port: Any = ReflectionHelpers.getField(it, "mPort")
        val handle: Any = ReflectionHelpers.getField(port, "mHandle")
        ReflectionHelpers.setField(handle, "mId", 7)
    }
    private fun hear(screen: StudyCallActivity, words: String) {
        ReflectionHelpers.callInstanceMethod<Any>(screen, "acceptSpeech", ReflectionHelpers.ClassParameter.from(List::class.java, listOf(words)))
    }
    private fun withCall(test: (StudyCallActivity, String, org.robolectric.shadows.ShadowTextToSpeech) -> Unit) {
        val row = StudyCalls.validate(args(), 1, true).put("status", "answered").put("answered_at", System.currentTimeMillis())
        store(row)
        val controller = Robolectric.buildActivity(StudyCallActivity::class.java,
            Intent(context, StudyCallActivity::class.java).putExtra("id", row.getString("id"))).create()
        try {
            val screen = controller.get()
            assertFalse(screen.isFinishing)
            val receiver = device()
            shadowOf(screen.getSystemService(AudioManager::class.java)).setAvailableCommunicationDevices(listOf(receiver))
            ShadowAudioTrack.setRoutedDevice(receiver)
            ShadowTextToSpeech.addLanguageAvailability(Locale.forLanguageTag("sv-SE"))
            val tts = shadowOf(ShadowTextToSpeech.getLastTextToSpeechInstance())
            tts.onInitListener.onInit(TextToSpeech.SUCCESS)
            controller.start().resume().visible(); idle(350)
            assertEquals(1, tts.spokenTextList.size)
            test(screen, row.getString("id"), tts)
        } finally { controller.pause().stop().destroy() }
    }

    @Test fun repeatWaitAndContinueNeverUseAttemptsAndRespectConfiguredSilence() = withCall { screen, id, tts ->
        hear(screen, "en gång till")
        idle(1999); assertEquals(1, tts.spokenTextList.size)
        idle(1); assertEquals(2, tts.spokenTextList.size)
        hear(screen, "vänta"); idle(20_000)
        assertEquals(2, tts.spokenTextList.size)
        hear(screen, "något annat"); idle(1000)
        assertEquals(0, StudyCalls.find(context, id)!!.getJSONArray("attempts").length())
        hear(screen, "kör")
        assertEquals(3, tts.spokenTextList.size)
        assertEquals(0, StudyCalls.find(context, id)!!.getJSONArray("attempts").length())
    }

    @Test fun waitingCancelsAnAutomaticRetryAndRepeatedCommandsCannotLeaveExtraTimers() = withCall { screen, id, tts ->
        hear(screen, "Göteborg")
        assertEquals(1, StudyCalls.find(context, id)!!.getJSONArray("attempts").length())
        idle(1000); hear(screen, "vänta"); idle(10_000)
        assertEquals(1, tts.spokenTextList.size)
        hear(screen, "igen"); idle(1000); hear(screen, "igen")
        idle(1999); assertEquals(1, tts.spokenTextList.size)
        idle(1); assertEquals(2, tts.spokenTextList.size)
        idle(5000); assertEquals(2, tts.spokenTextList.size)
        assertEquals(1, StudyCalls.find(context, id)!!.getJSONArray("attempts").length())
    }

    @Test fun callbackReschedulesExactlyOncePreservesSettingsAndRejectsLateActions() {
        for (minutes in listOf(5, 10, 15)) {
            val row = StudyCalls.validate(args(), 7, true).put("status", "declined").put("finished_at", System.currentTimeMillis())
            store(row)
            val id = row.getString("id"); val before = System.currentTimeMillis()
            val armed = mutableListOf<JSONObject>()
            StudyCalls.callBack(context, id, minutes) { _, call -> armed.add(call) }
            val saved = StudyCalls.find(context, id)!!
            assertEquals("scheduled", saved.getString("status"))
            assertTrue(saved.getLong("when_ms") in before + minutes * 60_000L..System.currentTimeMillis() + minutes * 60_000L)
            assertEquals(1, armed.size); assertEquals(7, saved.getInt("profile_id"))
            assertEquals(2.0, saved.getDouble("repetition_pause_seconds"), 0.001)
            assertEquals(0.75, saved.getDouble("speech_rate"), 0.001)
            assertFalse(saved.has("finished_at")); assertEquals(0, saved.getJSONArray("attempts").length())
            try { StudyCalls.callBack(context, id, minutes) { _, _ -> fail("duplicate alarm") }; fail("duplicate callback") }
            catch (error: IllegalStateException) { assertEquals("not_declined", error.message) }
            StudyCalls.fire(context, id) // A queued alarm from the old ring cannot ring early.
            assertEquals("scheduled", StudyCalls.find(context, id)!!.getString("status"))
        }
    }

    @Test fun callbackFailureRestoresTheDeclinedCallAndEnforcesCapacity() {
        val row = StudyCalls.validate(args(), 1, true).put("status", "declined")
        val id = row.getString("id"); store(row)
        try { StudyCalls.callBack(context, id, 5) { _, _ -> error("alarm_failed") }; fail("alarm failure") }
        catch (error: IllegalStateException) { assertEquals("alarm_failed", error.message) }
        assertEquals("declined", StudyCalls.find(context, id)!!.getString("status"))
        StudyCalls.setPendingLimit(context, 1)
        store(row, StudyCalls.validate(args(), 2, true).put("status", "disabled"))
        try { StudyCalls.callBack(context, id, 5); fail("capacity") }
        catch (error: IllegalStateException) { assertEquals("too_many_calls", error.message) }
        assertEquals("declined", StudyCalls.find(context, id)!!.getString("status"))
    }

    @Test fun decliningOpensScrollableCallbackChoicesWithoutSpeaking() {
        val row = StudyCalls.validate(args(), 1, true).put("status", "ringing").put("fired_at", System.currentTimeMillis())
        store(row)
        val controller = Robolectric.buildActivity(StudyCallDeclineActivity::class.java,
            StudyCalls.declineIntent(context, row.getString("id"))).setup()
        try {
            fun descendants(view: View): List<View> = listOf(view) + if (view is ViewGroup)
                (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()
            val views = descendants(controller.get().findViewById(android.R.id.content))
            assertTrue(views.any { it is android.widget.ScrollView })
            assertEquals(listOf("Call back in 5 minutes", "Call back in 10 minutes", "Call back in 15 minutes", "Dismiss without callback"),
                views.filterIsInstance<Button>().map { it.text.toString() })
            assertEquals("declined", StudyCalls.find(context, row.getString("id"))!!.getString("status"))
            views.filterIsInstance<Button>().last().performClick()
            assertTrue(controller.get().isFinishing)
            assertEquals("declined", StudyCalls.find(context, row.getString("id"))!!.getString("status"))
        } finally { controller.pause().stop().destroy() }
    }
}
