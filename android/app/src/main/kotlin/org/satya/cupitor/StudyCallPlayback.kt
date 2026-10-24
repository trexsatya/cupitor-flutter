package org.satya.cupitor

import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRouting
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper

/** The selected communication device can change before playback actually moves.
 * Keep a zero-PCM call track active so routing can settle without exposing speech. */
interface StudyCallPlayback {
    fun start(onRoutingChanged: () -> Unit)
    fun routedDevices(): List<AudioDeviceInfo>
    fun close()
}

class SilentStudyCallPlayback : StudyCallPlayback {
    private var track: AudioTrack? = null
    private var listener: AudioRouting.OnRoutingChangedListener? = null

    override fun start(onRoutingChanged: () -> Unit) {
        if (track != null) return
        val rate = 16_000
        val size = maxOf(6_400, AudioTrack.getMinBufferSize(rate,
            AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)).let { it + it % 2 }
        val output = AudioTrack.Builder().setAudioAttributes(StudyCallAudio.attributes)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(size).build()
        track = output
        try {
            val silence = ByteArray(size)
            check(output.write(silence, 0, silence.size, AudioTrack.WRITE_BLOCKING) == silence.size)
            check(output.setLoopPoints(0, silence.size / 2, -1) == AudioTrack.SUCCESS)
            listener = AudioRouting.OnRoutingChangedListener { onRoutingChanged() }.also {
                output.addOnRoutingChangedListener(it, Handler(Looper.getMainLooper()))
            }
            output.play()
        } catch (error: Exception) { close(); throw error }
    }

    override fun routedDevices(): List<AudioDeviceInfo> {
        val output = track ?: return emptyList()
        if (output.playState != AudioTrack.PLAYSTATE_PLAYING) return emptyList()
        // API 36 can report simultaneous outputs. Do not accept a private route
        // if the same communication playback is also sent to the speaker.
        return if (Build.VERSION.SDK_INT >= 36) output.routedDevices
            else listOfNotNull(output.routedDevice)
    }

    override fun close() {
        val output = track ?: return
        track = null
        listener?.let { try { output.removeOnRoutingChangedListener(it) } catch (_: Exception) {} }
        listener = null
        try { output.stop() } catch (_: Exception) {}
        output.release()
    }
}
