package org.satya.cupitor

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executor

/** Owns communication routing only while an answered study call is visible.
 * TTS and recognition keep the same route across their turn-taking. */
@Suppress("DEPRECATION")
class StudyCallAudio(private val context: Context, initialSpeaker: Boolean = false, private val changed: (State) -> Unit) {
    data class State(val ready: Boolean, val label: String, val speaker: Boolean = false,
                     val canToggleSpeaker: Boolean = false)

    companion object {
        val attributes: AudioAttributes get() = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()

        private fun external(type: Int) = type in setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_HEARING_AID)

        internal fun preferred(devices: List<AudioDeviceInfo>, speaker: Boolean, current: AudioDeviceInfo?): AudioDeviceInfo? {
            if (speaker) return devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            // A newly plugged cable takes precedence; otherwise keep the active
            // external route when multiple headsets are connected.
            return devices.firstOrNull { it.type in setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE) }
                ?: devices.firstOrNull { external(it.type) && it.id == current?.id }
                ?: devices.firstOrNull { external(it.type) }
                ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
        }
    }

    private val audio = requireNotNull(context.getSystemService(AudioManager::class.java))
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executor { handler.post(it) }
    private var active = false
    private var requested: AudioDeviceInfo? = null
    private var speakerRequested = initialSpeaker
    val speakerPreferred get() = speakerRequested
    private var previousSpeaker = false
    private var scoStarted = false
    private var scoFailed = false
    private var timer: Runnable? = null
    private var communicationListener: AudioManager.OnCommunicationDeviceChangedListener? = null
    var state = State(false, "Audio not active")
        private set

    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            if (addedDevices.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }) scoFailed = false
            updateRoute()
        }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) { updateRoute() }
        private fun updateRoute() { handler.post { if (active) selectRoute() } }
    }
    private val scoReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (!active || !scoStarted) return
            when (intent?.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)) {
                AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                    audio.isBluetoothScoOn = true
                    ready("Bluetooth headset", false)
                }
                AudioManager.SCO_AUDIO_STATE_DISCONNECTED, AudioManager.SCO_AUDIO_STATE_ERROR -> {
                    val previous = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_PREVIOUS_STATE, -1)
                    if (intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1) == AudioManager.SCO_AUDIO_STATE_DISCONNECTED &&
                        previous !in setOf(AudioManager.SCO_AUDIO_STATE_CONNECTED, AudioManager.SCO_AUDIO_STATE_CONNECTING) && !state.ready) return
                    scoFailed = true; stopSco(); requested = null; selectRoute()
                }
            }
        }
    }

    fun start(): Boolean {
        if (active) {
            if (audio.mode != AudioManager.MODE_IN_COMMUNICATION) stop("Call audio was interrupted. Tap Read again to resume.")
            return state.ready
        }
        if (audio.mode != AudioManager.MODE_NORMAL) {
            publish(State(false, "Audio is busy with another call. Try Read again later.")); return false
        }
        active = true
        previousSpeaker = audio.isSpeakerphoneOn
        try {
            audio.mode = AudioManager.MODE_IN_COMMUNICATION
            if (audio.mode != AudioManager.MODE_IN_COMMUNICATION) { stop("Call audio is unavailable."); return false }
            if (Build.VERSION.SDK_INT >= 31) {
                communicationListener = AudioManager.OnCommunicationDeviceChangedListener {
                    if (active) {
                        val device = audio.communicationDevice
                        if (device != null && device.id == requested?.id) ready(label(device), device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
                        else if (state.ready) {
                            requested = null
                            publish(State(false, "Call audio route changed…"))
                            selectRoute()
                        }
                    }
                }.also { audio.addOnCommunicationDeviceChangedListener(executor, it) }
            } else context.registerReceiver(scoReceiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))
            audio.registerAudioDeviceCallback(devices, handler)
            selectRoute()
        } catch (_: Exception) { stop("Could not route call audio. You can answer on screen.") }
        return state.ready
    }

    fun setSpeaker(enabled: Boolean) {
        speakerRequested = enabled
        if (active) { requested = null; selectRoute() } else start()
    }

    private fun available(): List<AudioDeviceInfo> = if (Build.VERSION.SDK_INT >= 31) audio.availableCommunicationDevices
        else audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { !scoFailed || it.type != AudioDeviceInfo.TYPE_BLUETOOTH_SCO }

    private fun selectRoute() {
        if (!active) return
        try {
            val routes = available()
            val current = if (Build.VERSION.SDK_INT >= 31) audio.communicationDevice else requested
            val target = preferred(routes, speakerRequested, current)
            if (target == null) {
                if (Build.VERSION.SDK_INT < 31) {
                    // Older devices may not enumerate the built-in receiver.
                    stopSco(); audio.isSpeakerphoneOn = speakerRequested
                    ready(if (speakerRequested) "Speaker" else "Phone / connected headset", speakerRequested)
                } else stop("No call audio device is available. You can answer on screen.")
                return
            }
            if (requested?.id == target.id && (state.ready || timer != null)) return
            requested = target
            publish(State(false, "Connecting ${label(target).lowercase()}…", target.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, canToggle(routes)))
            timer?.let(handler::removeCallbacks)
            timer = null
            if (Build.VERSION.SDK_INT >= 31) {
                if (!audio.setCommunicationDevice(target)) {
                    if (target.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE && routes.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }) {
                        speakerRequested = false
                        val receiver = routes.first { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
                        requested = receiver
                        if (audio.setCommunicationDevice(receiver)) {
                            if (audio.communicationDevice?.id == receiver.id) ready("Phone earpiece (headset unavailable)", false)
                            else waitForRoute()
                            return
                        }
                    }
                    stop("Could not select call audio. Reconnect your headset or tap Read again."); return
                }
                if (audio.communicationDevice?.id == target.id) ready(label(target), target.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
                else waitForRoute()
            } else {
                audio.isSpeakerphoneOn = target.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                if (target.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
                    if (audio.isBluetoothScoOn) ready(label(target), false)
                    else { scoStarted = true; audio.startBluetoothSco(); waitForRoute() }
                } else { stopSco(); ready(label(target), target.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) }
            }
        } catch (_: Exception) { stop("Could not route call audio. You can answer on screen.") }
    }

    private fun waitForRoute() {
        timer = Runnable {
            if (active && !state.ready) stop("The headset did not connect. Reconnect it or tap Read again.")
        }.also { handler.postDelayed(it, 30_000) }
    }
    private fun ready(label: String, speaker: Boolean) {
        timer?.let(handler::removeCallbacks); timer = null
        publish(State(true, label, speaker, canToggle(available())))
    }
    private fun canToggle(routes: List<AudioDeviceInfo>) = routes.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER } &&
        routes.any { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE || external(it.type) }
    private fun label(device: AudioDeviceInfo) = when (device.type) {
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Phone earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speaker"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_HEARING_AID -> "Bluetooth headset"
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> "USB headset"
        else -> "Wired headset"
    }
    private fun publish(value: State) { if (state != value) { state = value; changed(value) } }
    private fun stopSco() {
        if (scoStarted) { audio.stopBluetoothSco(); audio.isBluetoothScoOn = false; scoStarted = false }
    }

    fun stop(reason: String = "Audio stopped") {
        val wasActive = active
        active = false
        timer?.let(handler::removeCallbacks); timer = null
        if (wasActive) {
            try { audio.unregisterAudioDeviceCallback(devices) } catch (_: Exception) {}
            if (Build.VERSION.SDK_INT >= 31) {
                communicationListener?.let { try { audio.removeOnCommunicationDeviceChangedListener(it) } catch (_: Exception) {} }
                try { audio.clearCommunicationDevice() } catch (_: Exception) {}
            } else {
                try { context.unregisterReceiver(scoReceiver) } catch (_: Exception) {}
                try { stopSco(); if (audio.mode == AudioManager.MODE_IN_COMMUNICATION) audio.isSpeakerphoneOn = previousSpeaker } catch (_: Exception) {}
            }
            try { audio.mode = AudioManager.MODE_NORMAL } catch (_: Exception) {}
        }
        communicationListener = null; requested = null
        publish(State(false, reason))
    }
}
