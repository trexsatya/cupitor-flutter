package org.satya.cupitor

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.Locale

/** Installed/default-engine TTS voices. Recording and speech recognition keep
 * their own language; these settings only change the question's speaking voice. */
object StudyCallSpeech {
    private val main = Handler(Looper.getMainLooper())
    private var preview: TextToSpeech? = null
    private var previewAudio: AudioManager? = null
    private var generation = 0
    private val focusListener = AudioManager.OnAudioFocusChangeListener { if (it < 0) stopPreview() }

    fun validate(args: Map<*, *>): Map<String, Any> {
        val out = mutableMapOf<String, Any>()
        if (args.containsKey("voice_name")) {
            val name = args["voice_name"] as? String ?: error("bad_voice")
            check(name.length <= 200) { "bad_voice" }
            out["voice_name"] = name.trim()
        }
        if (args.containsKey("speech_rate")) {
            val rate = (args["speech_rate"] as? Number)?.toDouble() ?: error("bad_voice")
            check(rate.isFinite() && rate in 0.5..1.5) { "bad_voice" }
            out["speech_rate"] = rate
        }
        return out
    }

    fun defaults(context: Context): Map<String, Any> {
        val prefs = context.getSharedPreferences("study_calls", Context.MODE_PRIVATE)
        return mapOf("voice_name" to (prefs.getString("voice_name", "") ?: ""),
            "speech_rate" to prefs.getFloat("speech_rate", 1f).toDouble())
    }

    fun options(voices: Set<Voice>): List<Map<String, Any>> = voices
        .filter { !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) }
        .sortedWith(compareBy<Voice> { it.locale.toLanguageTag() }.thenBy { it.name })
        .map { mapOf("name" to it.name, "language" to it.locale.toLanguageTag(),
            "label" to "${it.locale.displayName} · ${it.name}", "network" to it.isNetworkConnectionRequired) }

    fun configure(engine: TextToSpeech, context: Context, row: JSONObject): Int {
        val locale = Locale.forLanguageTag(row.optString("language", "sv-SE"))
        val result = engine.setLanguage(locale)
        val settings = defaults(context)
        val name = row.optString("voice_name", settings["voice_name"] as String)
        engine.voices.orEmpty().firstOrNull { it.name == name && it.locale.language == locale.language }?.let { engine.setVoice(it) }
        engine.setSpeechRate(row.optDouble("speech_rate", (settings["speech_rate"] as Number).toDouble()).toFloat())
        return result
    }

    private fun initialize(context: Context, reply: MethodChannel.Result, ready: (TextToSpeech) -> Unit) {
        var engine: TextToSpeech? = null
        var settled = false
        val timeout = Runnable {
            if (!settled) { settled = true; engine?.shutdown(); reply.error("speech_unavailable", null, null) }
        }
        engine = TextToSpeech(context.applicationContext) { status -> main.post {
            if (settled) return@post
            settled = true; main.removeCallbacks(timeout)
            val instance = engine
            if (status != TextToSpeech.SUCCESS || instance == null) {
                instance?.shutdown(); reply.error("speech_unavailable", null, null)
            } else try { ready(instance) } catch (_: Exception) {
                instance.shutdown(); reply.error("speech_unavailable", null, null)
            }
        } }
        main.postDelayed(timeout, 10_000)
    }

    fun getVoices(context: Context, reply: MethodChannel.Result) = initialize(context, reply) { engine ->
        try { reply.success(mapOf("voices" to options(engine.voices.orEmpty()))) }
        finally { engine.shutdown() }
    }

    fun stopPreview() {
        generation++
        preview?.stop(); preview?.shutdown(); preview = null
        @Suppress("DEPRECATION")
        previewAudio?.abandonAudioFocus(focusListener)
        previewAudio = null
    }

    fun preview(context: Context, args: Map<*, *>, reply: MethodChannel.Result) {
        val settings = validate(args)
        val language = args["language"] as? String ?: "sv-SE"
        check(language.matches(Regex("[a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?"))) { "bad_voice" }
        stopPreview()
        val token = generation
        initialize(context, reply) { engine ->
            if (token != generation || StudyCalls.visibleCallId != null || StudyCalls.read(context).any { it.optString("status") in setOf("ringing", "answered") }) {
                engine.shutdown(); reply.error("busy", null, null)
            } else {
                preview = engine
                val row = JSONObject(settings).put("language", language)
                val result = configure(engine, context, row)
                if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                    stopPreview(); reply.error("speech_unavailable", null, null)
                } else {
                    val audio = context.getSystemService(AudioManager::class.java)
                    @Suppress("DEPRECATION")
                    val focus = audio?.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    if (focus != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                        stopPreview(); reply.error("busy", null, null)
                    } else {
                        previewAudio = audio
                        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                            override fun onStart(id: String?) {}
                            override fun onDone(id: String?) { main.post { if (token == generation) stopPreview() } }
                            @Deprecated("Deprecated in Java")
                            override fun onError(id: String?) { main.post { if (token == generation) stopPreview() } }
                        })
                        val text = if (language.startsWith("sv")) "Hej! Det här är din studieröst. Vilket svar väljer du?" else "Hello! This is your study voice. Which answer do you choose?"
                        if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "study-voice-preview") == TextToSpeech.ERROR) {
                            stopPreview(); reply.error("speech_unavailable", null, null)
                        } else {
                            reply.success(true)
                            main.postDelayed({ if (token == generation) stopPreview() }, 30_000)
                        }
                    }
                }
            }
        }
    }
}
