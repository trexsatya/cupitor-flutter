package org.satya.cupitor

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Looper
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.ShadowAudioManager
import org.robolectric.util.ReflectionHelpers
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class StudyCallAudioTest {
    private lateinit var context: Activity
    private lateinit var audio: AudioManager
    private var nextId = 0
    private fun device(type: Int): AudioDeviceInfo = AudioDeviceInfoBuilder.newBuilder().setType(type).build().also {
        val port: Any = ReflectionHelpers.getField(it, "mPort")
        val handle: Any = ReflectionHelpers.getField(port, "mHandle")
        ReflectionHelpers.setField(handle, "mId", ++nextId)
    }
    private fun devices(vararg devices: AudioDeviceInfo) {
        shadowOf(audio).setAvailableCommunicationDevices(devices.toList())
    }
    private fun idle() { shadowOf(Looper.getMainLooper()).idle() }
    @Before fun setup() {
        context = Robolectric.buildActivity(Activity::class.java).setup().get()
        audio = context.getSystemService(AudioManager::class.java)!!
    }

    @Test fun answeredAudioUsesTheReceiverAndReleasesItsModeAndDevice() {
        val receiver = device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
        devices(device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER), receiver)
        val session = StudyCallAudio(context) {}
        assertTrue(session.start())
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audio.mode)
        assertEquals(receiver.id, audio.communicationDevice!!.id)
        assertFalse(session.state.speaker)
        assertEquals(AudioAttributes.USAGE_VOICE_COMMUNICATION, StudyCallAudio.attributes.usage)
        assertEquals(AudioManager.STREAM_VOICE_CALL, StudyCallAudio.attributes.volumeControlStream)
        session.stop(); idle()
        assertEquals(AudioManager.MODE_NORMAL, audio.mode)
        assertNull(audio.communicationDevice)
        assertFalse(session.state.ready)
        session.stop() // cleanup is idempotent
    }

    @Test fun prefersAConnectedHeadsetOverTheReceiverForEachSupportedCallTransport() {
        for (type in listOf(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_HEARING_AID)) {
            val headset = device(type)
            devices(device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE), device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER), headset)
            val session = StudyCallAudio(context) {}
            assertTrue(session.start())
            assertEquals(headset.id, audio.communicationDevice!!.id)
            assertFalse(session.state.speaker)
            session.stop(); idle()
        }
    }

    @Test fun speakerIsExplicitAndSwitchingItOffReturnsToTheHeadset() {
        val headset = device(AudioDeviceInfo.TYPE_BLE_HEADSET)
        val speaker = device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        devices(speaker, headset, device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        val session = StudyCallAudio(context) {}
        assertTrue(session.start()); assertTrue(session.state.canToggleSpeaker)
        session.setSpeaker(true)
        assertEquals(speaker.id, audio.communicationDevice!!.id)
        assertTrue(session.state.speaker)
        session.setSpeaker(false)
        assertEquals(headset.id, audio.communicationDevice!!.id)
        assertFalse(session.state.speaker)
        session.stop()
    }

    @Test fun pluggingAndUnpluggingAHeadsetUpdatesTheRouteWithoutSelectingTheSpeaker() {
        val receiver = device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
        devices(receiver, device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        val states = mutableListOf<StudyCallAudio.State>()
        val session = StudyCallAudio(context) { states += it }
        session.start(); idle()
        val headset = device(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        shadowOf(audio).addAvailableCommunicationDevice(headset, true); idle()
        assertEquals(headset.id, audio.communicationDevice!!.id)
        shadowOf(audio).removeAvailableCommunicationDevice(headset, true); idle()
        assertEquals(receiver.id, audio.communicationDevice!!.id)
        assertFalse(states.any { it.speaker })
        assertTrue(states.any { !it.ready })
        session.stop()
        val count = states.size
        shadowOf(audio).addAvailableCommunicationDevice(headset, true); idle()
        assertNull(audio.communicationDevice)
        assertEquals(count, states.size)
    }

    @Test fun anotherCallIsNotTakenOverAndRefusedRoutesDoNotRemainActive() {
        audio.mode = AudioManager.MODE_IN_CALL
        val session = StudyCallAudio(context) {}
        assertFalse(session.start())
        assertEquals(AudioManager.MODE_IN_CALL, audio.mode)
        audio.mode = AudioManager.MODE_NORMAL
        devices(device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE), device(AudioDeviceInfo.TYPE_BLE_HEADSET))
        shadowOf(audio).lockCommunicationDevice(true)
        assertFalse(session.start())
        assertFalse(session.state.ready)
        assertEquals(AudioManager.MODE_NORMAL, audio.mode)
        assertNull(audio.communicationDevice)
        shadowOf(audio).lockCommunicationDevice(false)
        assertTrue(session.start())
        session.stop()
    }

    @Test fun aTabletUsesItsSpeakerOnlyWhenNoPrivateRouteExists() {
        devices(device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        val session = StudyCallAudio(context) {}
        assertTrue(session.start())
        assertTrue(session.state.speaker)
        assertFalse(session.state.canToggleSpeaker)
        session.stop()
    }

    @Test @Config(shadows = [DelayedRouteAudioManager::class])
    fun communicationAudioWaitsUntilTheRequestedDeviceIsActuallyActive() {
        val headset = device(AudioDeviceInfo.TYPE_BLE_HEADSET)
        devices(headset, device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        val session = StudyCallAudio(context) {}
        assertFalse(session.start())
        assertFalse(session.state.ready)
        assertNull(audio.communicationDevice)
        Shadow.extract<DelayedRouteAudioManager>(audio).completeRoute()
        idle()
        assertTrue(session.state.ready)
        assertEquals(headset.id, audio.communicationDevice!!.id)
        session.stop()
    }

    @Test @Config(sdk = [24], shadows = [LegacyScoAudioManager::class])
    fun legacyBluetoothWaitsForScoAndDisconnectsCleanly() {
        val headset = device(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        shadowOf(audio).setOutputDevices(listOf(headset, device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)))
        val session = StudyCallAudio(context) {}
        assertFalse(session.start())
        assertFalse(session.state.ready)
        val legacy = Shadow.extract<LegacyScoAudioManager>(audio)
        assertEquals(1, legacy.starts)
        // Initial sticky DISCONNECTED must not cancel a new connection.
        context.sendBroadcast(Intent(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
            .putExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.SCO_AUDIO_STATE_DISCONNECTED))
        idle(); assertFalse(session.state.ready); assertEquals(1, legacy.starts)
        context.sendBroadcast(Intent(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
            .putExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, AudioManager.SCO_AUDIO_STATE_CONNECTED))
        idle()
        assertTrue(session.state.ready)
        assertTrue(audio.isBluetoothScoOn)
        session.stop()
        assertFalse(audio.isBluetoothScoOn)
        assertEquals(1, legacy.stops)
        assertEquals(AudioManager.MODE_NORMAL, audio.mode)
    }

    @Test @Config(sdk = [24], shadows = [LegacyScoAudioManager::class])
    fun legacyConnectionTimeoutReleasesAudioWithoutReadingThroughTheSpeaker() {
        shadowOf(audio).setOutputDevices(listOf(device(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)))
        val session = StudyCallAudio(context) {}
        assertFalse(session.start())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(31))
        assertFalse(session.state.ready)
        assertEquals(AudioManager.MODE_NORMAL, audio.mode)
        assertFalse(audio.isBluetoothScoOn)
    }
}

/** Robolectric 4.14 does not shadow the legacy SCO binder calls. */
@Implements(AudioManager::class)
class LegacyScoAudioManager : ShadowAudioManager() {
    var starts = 0
    var stops = 0
    @Implementation fun startBluetoothSco() { starts++ }
    @Implementation fun stopBluetoothSco() { stops++ }
}

@Implements(AudioManager::class)
class DelayedRouteAudioManager : ShadowAudioManager() {
    private var pending: AudioDeviceInfo? = null
    @Implementation(minSdk = 31)
    public override fun setCommunicationDevice(device: AudioDeviceInfo): Boolean {
        pending = device
        return true
    }
    fun completeRoute() {
        pending?.let {
            super.setCommunicationDevice(it)
            callOnCommunicationDeviceChangedListeners(it)
        }
    }
}
