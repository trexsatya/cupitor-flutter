package org.satya.cupitor

import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Looper
import android.speech.tts.TextToSpeech
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.ShadowAudioTrack
import org.robolectric.shadows.ShadowTextToSpeech
import org.robolectric.util.ReflectionHelpers
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class StudyCallPlaybackTest {
    private fun device(type: Int, id: Int): AudioDeviceInfo = AudioDeviceInfoBuilder.newBuilder().setType(type).build().also {
        val port: Any = ReflectionHelpers.getField(it, "mPort")
        val handle: Any = ReflectionHelpers.getField(port, "mHandle")
        ReflectionHelpers.setField(handle, "mId", id)
    }

    @Test fun warmupWritesOnlyZeroPcmAndObservesTheActualRouteUntilClosed() {
        val writes = mutableListOf<ByteArray>()
        var actualTrack: AudioTrack? = null
        val observer = ShadowAudioTrack.OnAudioDataWrittenListener { track, bytes, _ ->
            writes += bytes.clone()
            actualTrack = ReflectionHelpers.getField(track, "audioTrack")
        }
        ShadowAudioTrack.addAudioDataListener(observer)
        val output = SilentStudyCallPlayback()
        try {
            output.start {}
            assertTrue(writes.isNotEmpty())
            assertTrue(writes.all { bytes -> bytes.all { it == 0.toByte() } })
            assertEquals(AudioTrack.PLAYSTATE_PLAYING, actualTrack!!.playState)
            assertTrue(output.routedDevices().isEmpty())
            val receiver = device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, 7)
            ShadowAudioTrack.setRoutedDevice(receiver)
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(listOf(receiver.id), output.routedDevices().map { it.id })
            output.close()
            assertTrue(output.routedDevices().isEmpty())
            assertEquals(AudioTrack.STATE_UNINITIALIZED, actualTrack!!.state)
        } finally {
            output.close()
            ShadowAudioTrack.removeAudioDataListener(observer)
        }
    }

    @Test fun nativeQuestionIsNotQueuedUntilPlaybackActuallyReachesTheEarpiece() {
        val app = RuntimeEnvironment.getApplication()
        val row = StudyCalls.validate(mapOf("title" to "Test", "question" to "Private study question",
            "choices" to listOf("One", "Two"), "language" to "en-GB", "voice_response" to false), 1, true)
            .put("status", "answered")
        app.getSharedPreferences("study_calls", 0).edit().clear()
            .putString("calls", JSONArray(listOf(row)).toString()).commit()
        val controller = Robolectric.buildActivity(StudyCallActivity::class.java,
            Intent(app, StudyCallActivity::class.java).putExtra("id", row.getString("id"))).create()
        try {
            val screen = controller.get()
            val audio = screen.getSystemService(AudioManager::class.java)!!
            val receiver = device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE, 1)
            val speaker = device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, 2)
            shadowOf(audio).setAvailableCommunicationDevices(listOf(receiver, speaker))
            ShadowAudioTrack.setRoutedDevice(speaker)
            val tts = ShadowTextToSpeech.getLastTextToSpeechInstance()
            shadowOf(tts).onInitListener.onInit(TextToSpeech.SUCCESS)
            controller.start().resume().visible()
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
            assertEquals(receiver.id, audio.communicationDevice!!.id)
            assertNull(shadowOf(tts).lastSpokenText)
            ShadowAudioTrack.setRoutedDevice(receiver)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(StudyCallAudio.SETTLE_MS - 1))
            assertNull(shadowOf(tts).lastSpokenText)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1))
            assertTrue(shadowOf(tts).lastSpokenText.contains("Private study question"))
        } finally { controller.pause().stop().destroy() }
    }
}
