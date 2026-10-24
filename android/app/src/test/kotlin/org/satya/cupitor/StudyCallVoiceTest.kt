package org.satya.cupitor

import android.Manifest
import android.app.Activity
import android.os.Bundle
import android.os.Looper
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSpeechRecognizer
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 34], manifest = Config.NONE)
class StudyCallVoiceTest {
    private lateinit var context: Activity
    private var active = true
    private var available = true
    private val failures = mutableListOf<Pair<String, Boolean>>()
    private val results = mutableListOf<List<String>>()
    private val statuses = mutableListOf<String>()
    @Before fun setup() {
        context = Robolectric.buildActivity(Activity::class.java).setup().get()
        shadowOf(context.application).grantPermissions(Manifest.permission.RECORD_AUDIO)
    }
    private fun voice() = StudyCallVoice(context, { active }, { statuses.add(it) }, {},
        { results.add(it) }, { message, counts -> failures.add(message to counts) }, { available })
    private fun idle(ms: Long = 0) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun engine(): ShadowSpeechRecognizer = shadowOf(requireNotNull(ShadowSpeechRecognizer.getLatestSpeechRecognizer()))
    private fun heard(vararg words: String) = Bundle().apply {
        putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, ArrayList(words.toList()))
    }

    @Test fun temporaryFailuresRecoverAndDeliverOneResultWithoutUsingAnAnswerAttempt() {
        for (error in listOf(SpeechRecognizer.ERROR_AUDIO, SpeechRecognizer.ERROR_CLIENT,
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
            SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_TOO_MANY_REQUESTS)) {
            failures.clear(); results.clear()
            val voice = voice()
            voice.start("sv-SE"); idle()
            val first = engine()
            first.triggerOnError(error)
            assertTrue(first.isDestroyed)
            assertTrue(voice.listening)
            assertTrue(failures.isEmpty())
            first.triggerOnResults(heard("late result"))
            idle(6000)
            val replacement = engine()
            assertNotSame(first, replacement)
            assertEquals("sv-SE", replacement.lastRecognizerIntent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE))
            replacement.triggerOnReadyForSpeech(Bundle())
            replacement.triggerOnResults(heard("Stockholm"))
            assertEquals(listOf(listOf("Stockholm")), results)
            assertTrue(failures.isEmpty()); assertFalse(voice.listening)
            assertTrue(replacement.isDestroyed)
            first.triggerOnError(error)
            idle(20_000)
            assertEquals(1, results.size); assertTrue(failures.isEmpty())
            voice.cancel()
        }
    }

    @Test fun recoveryIsBoundedAndReportsTheActualErrorInsteadOfUsingQuestionRetries() {
        val voice = voice()
        voice.start("sv-SE"); idle()
        val first = engine(); first.triggerOnError(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
        idle(749); assertSame(first, engine())
        idle(1); val second = engine(); assertNotSame(first, second)
        second.triggerOnError(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
        idle(1499); assertSame(second, engine())
        idle(1); val third = engine(); assertNotSame(second, third)
        third.triggerOnError(SpeechRecognizer.ERROR_RECOGNIZER_BUSY)
        assertFalse(voice.listening); assertEquals(1, failures.size)
        assertFalse(failures.single().second)
        assertTrue(failures.single().first.contains("busy"))
        assertTrue(failures.single().first.contains("error 8"))
        idle(30_000); assertSame(third, engine()); assertEquals(1, failures.size)
        voice.cancel()
    }

    @Test fun stopCancelsRecoveryAndLateCallbacksCannotReachTheNewSession() {
        val voice = voice()
        voice.start("sv-SE"); idle()
        val first = engine(); first.triggerOnError(SpeechRecognizer.ERROR_CLIENT)
        voice.cancel(); idle(3000)
        assertSame(first, engine()); assertFalse(voice.listening)
        assertTrue(failures.isEmpty())
        voice.start("en-GB"); idle()
        val second = engine(); assertNotSame(first, second)
        first.triggerOnResults(heard("stale")); first.triggerOnError(SpeechRecognizer.ERROR_AUDIO)
        assertTrue(results.isEmpty()); assertTrue(failures.isEmpty())
        second.triggerOnResults(heard("current"))
        assertEquals(listOf(listOf("current")), results)
        voice.cancel()
    }

    @Test fun leavingTheCallPreventsAQueuedRecoveryFromOpeningTheMicrophone() {
        val voice = voice()
        voice.start("sv-SE"); idle()
        val first = engine(); first.triggerOnError(SpeechRecognizer.ERROR_SERVER_DISCONNECTED)
        active = false; idle(10_000)
        assertSame(first, engine()); assertTrue(failures.isEmpty()); assertTrue(results.isEmpty())
        voice.cancel()
    }

    @Test fun availabilityIsCheckedAgainDuringRecovery() {
        available = false
        val voice = voice(); voice.start("sv-SE")
        assertTrue(voice.listening); assertTrue(failures.isEmpty())
        assertNull(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        available = true; idle(750)
        engine().triggerOnResults(heard("ready now"))
        assertEquals(listOf(listOf("ready now")), results)
        assertTrue(failures.isEmpty()); voice.cancel()
    }

    @Test fun aMissingServiceEndsWithActionableSettingsAndNoAnswerPenalty() {
        available = false
        val voice = voice(); voice.start("sv-SE")
        idle(2250)
        assertNull(ShadowSpeechRecognizer.getLatestSpeechRecognizer())
        assertFalse(voice.listening); assertEquals(1, failures.size)
        assertFalse(failures.single().second)
        assertTrue(failures.single().first.contains("Speech recognition settings"))
        voice.cancel()
    }

    @Test fun permissionAndLanguageProblemsAreSpecificAndNeverRetriedAsAnswers() {
        for ((error, expected) in listOf(SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS to "permission",
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED to "does not support sv-SE",
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE to "model for sv-SE",
            999 to "error 999")) {
            failures.clear()
            val voice = voice(); voice.start("sv-SE"); idle()
            val recognizer = engine(); recognizer.triggerOnError(error)
            assertEquals(1, failures.size); assertFalse(failures.single().second)
            assertTrue(failures.single().first.contains(expected))
            idle(10_000); assertSame(recognizer, engine()); assertFalse(voice.listening)
            voice.cancel()
        }
    }

    @Test fun genuineSilenceAndNoMatchStillUseTheConfiguredQuestionRetryBudget() {
        for (error in listOf(SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT)) {
            failures.clear()
            val voice = voice(); voice.start("sv-SE"); idle()
            engine().triggerOnReadyForSpeech(Bundle()); engine().triggerOnError(error)
            assertEquals(1, failures.size); assertTrue(failures.single().second)
            assertFalse(voice.listening); voice.cancel()
        }
    }

    @Test fun startupWatchdogRecoversWhileAnOpenedMicrophoneTimeoutCountsAsSilence() {
        val voice = voice(); voice.start("sv-SE"); idle()
        val first = engine(); idle(15_000)
        assertTrue(failures.isEmpty()); assertTrue(voice.listening)
        idle(750); assertNotSame(first, engine())
        engine().triggerOnReadyForSpeech(Bundle()); idle(15_000)
        assertEquals(1, failures.size); assertTrue(failures.single().second)
        assertFalse(voice.listening); voice.cancel()
    }

    @Test fun aNeverOpenedMicrophoneStopsAfterTwoRecoveriesWithoutSpendingAnAnswer() {
        val voice = voice(); voice.start("sv-SE"); idle(47_250)
        assertEquals(1, failures.size); assertFalse(failures.single().second)
        assertTrue(failures.single().first.contains("did not open"))
        assertFalse(voice.listening); voice.cancel()
    }

    @Test fun rapidCommandsWaitForThePreviousRecognizerToReleaseAndRemainCancellable() {
        val voice = voice(); voice.start("sv-SE"); idle()
        val first = engine(); first.triggerOnResults(heard("vänta"))
        voice.start("sv-SE")
        assertTrue(voice.listening)
        idle(StudyCallVoice.REARM_MS - 1); assertSame(first, engine())
        idle(1); assertNotSame(first, engine())
        voice.cancel(); assertFalse(voice.listening)
    }
}
