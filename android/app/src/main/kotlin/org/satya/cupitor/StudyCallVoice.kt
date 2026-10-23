package org.satya.cupitor

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/** Native recognizer so answered calls work without a Flutter engine/WebView.
 * One bounded attempt. The question owns the retry budget and grading. */
class StudyCallVoice(
    private val context: Context,
    private val isActive: () -> Boolean,
    private val onStatus: (String) -> Unit,
    private val onListening: (Boolean) -> Unit,
    private val onResult: (List<String>) -> Unit,
    private val onFailure: (String, Boolean) -> Unit,
) {
    companion object {
        fun available(context: Context): Boolean = try {
            SpeechRecognizer.isRecognitionAvailable(context)
        } catch (_: Exception) { false }
    }

    private val session = StudyCallVoiceSession()
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var timeout: Runnable? = null
    val listening get() = session.listening

    fun start(language: String) {
        cancel()
        if (!isActive()) return
        if (!available(context)) {
            onFailure("Speech recognition is unavailable. You can answer on screen.", false)
            return
        }
        val token = session.begin()
        onListening(true)
        onStatus("Starting microphone…")
        fun current() = session.isCurrent(token) && isActive()
        fun end(): Boolean {
            if (!session.complete(token)) return false
            release()
            onListening(false)
            return isActive()
        }
        try {
            val listener = object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    if (current()) onStatus("Listening…")
                }
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() { if (current()) onStatus("Checking your answer…") }
                override fun onPartialResults(partialResults: Bundle?) {
                    if (!current()) return
                    partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                        ?.takeIf { it.isNotBlank() }?.let { onStatus("Hearing: ${it.take(500)}") }
                }
                override fun onResults(results: Bundle?) {
                    if (!end()) return
                    val heard = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
                    if (heard.isNotEmpty()) onResult(heard.take(5).map { it.take(500) })
                    else onFailure("No answer heard.", true)
                }
                override fun onError(error: Int) {
                    if (!end()) return
                    val retryable = error in setOf(SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
                        SpeechRecognizer.ERROR_SERVER)
                    onFailure(when (error) {
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone access is needed. You can answer on screen."
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No clear answer heard."
                        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition could not connect."
                        else -> "Speech recognition is unavailable right now. You can answer on screen."
                    }, retryable)
                }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            }
            recognizer = SpeechRecognizer.createSpeechRecognizer(context).also { it.setRecognitionListener(listener) }
            timeout = Runnable {
                if (end()) onFailure("Listening timed out.", true)
            }.also { handler.postDelayed(it, 15_000) }
            recognizer?.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5))
        } catch (_: Exception) {
            if (end()) onFailure("Could not start speech recognition. You can answer on screen.", false)
        }
    }

    fun cancel() {
        session.cancel() // invalidate before cancel/destroy can trigger callbacks
        release()
        onListening(false)
    }

    private fun release() {
        timeout?.let(handler::removeCallbacks)
        timeout = null
        val old = recognizer
        recognizer = null
        try { old?.cancel() } catch (_: Exception) {}
        try { old?.destroy() } catch (_: Exception) {}
    }
}
