package org.satya.cupitor

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/** One answer turn may recover a broken speech service twice. Only actual
 * missing/unclear answers go back to the question's grading/retry budget. */
class StudyCallVoice(
    private val context: Context,
    private val isActive: () -> Boolean,
    private val onStatus: (String) -> Unit,
    private val onListening: (Boolean) -> Unit,
    private val onResult: (List<String>) -> Unit,
    private val onFailure: (String, Boolean) -> Unit,
    private val isAvailable: () -> Boolean = { available(context) },
) {
    companion object {
        internal const val MAX_RECOVERIES = 2
        internal const val REARM_MS = 350L
        fun available(context: Context): Boolean = try {
            SpeechRecognizer.isRecognitionAvailable(context)
        } catch (_: Exception) { false }
    }

    private val session = StudyCallVoiceSession()
    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var timeout: Runnable? = null
    private var pending: Runnable? = null
    private var generation = 0
    private var requested = false
    private var closedAt: Long? = null
    // Include reconnect backoff so Stop listening also cancels a queued restart.
    val listening get() = requested

    private fun current(request: Int) = request == generation && requested && isActive()

    fun start(language: String) {
        cancel()
        if (!isActive()) return
        requested = true
        val request = generation
        onListening(true)
        begin(language, request, 0)
    }

    private fun later(delay: Long, request: Int, action: () -> Unit) {
        pending?.let(handler::removeCallbacks)
        pending = Runnable {
            pending = null
            if (current(request)) action()
        }.also { handler.postDelayed(it, delay) }
    }

    private fun begin(language: String, request: Int, recoveries: Int) {
        if (!current(request)) return
        val remaining = closedAt?.let { REARM_MS - (SystemClock.uptimeMillis() - it) } ?: 0L
        if (remaining > 0) {
            onStatus("Starting microphone…")
            later(remaining, request) { begin(language, request, recoveries) }
            return
        }
        if (!isAvailable()) {
            recover(language, request, recoveries, "Android's speech service is not ready.",
                "Android could not find an enabled speech recognition service. Open Speech recognition settings, then tap Answer by voice.", 750L)
            return
        }
        val token = session.begin()
        onStatus("Starting microphone…")
        var microphoneOpened = false
        fun end(): Boolean {
            if (!current(request) || !session.complete(token)) return false
            // Results/errors have already ended this request. Sending cancel
            // here can race the next service binding; destroy is sufficient.
            release(cancel = false)
            return current(request)
        }
        try {
            val listener = object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    if (current(request) && session.isCurrent(token)) {
                        microphoneOpened = true
                        onStatus("Listening…")
                    }
                }
                override fun onBeginningOfSpeech() { if (session.isCurrent(token)) microphoneOpened = true }
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {
                    if (current(request) && session.isCurrent(token)) onStatus("Checking your answer…")
                }
                override fun onPartialResults(partialResults: Bundle?) {
                    if (!current(request) || !session.isCurrent(token)) return
                    partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                        ?.takeIf { it.isNotBlank() }?.let { microphoneOpened = true; onStatus("Hearing: ${it.take(500)}") }
                }
                override fun onResults(results: Bundle?) {
                    if (!end()) return
                    val heard = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
                        .take(5).map { it.take(500) }.filter { it.isNotBlank() }
                    if (heard.isEmpty()) fail(request, "No answer heard.", true)
                    else {
                        requested = false
                        onListening(false)
                        if (request == generation && isActive()) onResult(heard)
                    }
                }
                override fun onError(error: Int) {
                    if (!end()) return
                    when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                            fail(request, "No clear answer heard.", true)
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> fail(request,
                            "Microphone permission is missing (error $error). Allow Cupitor microphone access in Android app permissions, then try again.", false)
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> fail(request,
                            "The speech recognizer does not support $language (error $error). Choose another service in Speech recognition settings or answer on screen.", false)
                        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> fail(request,
                            "The speech model for $language is unavailable (error $error). Download or enable it in Speech recognition settings, then try again.", false)
                        SpeechRecognizer.ERROR_AUDIO, SpeechRecognizer.ERROR_CLIENT,
                        SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
                        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                        SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> {
                            val reason = when (error) {
                                SpeechRecognizer.ERROR_AUDIO -> "The microphone could not record audio."
                                SpeechRecognizer.ERROR_CLIENT -> "The speech service could not start."
                                SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The speech service is busy."
                                SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "The speech service disconnected."
                                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "The speech service could not connect."
                                SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "The speech service is limiting requests."
                                else -> "The speech service failed."
                            }
                            val help = when (error) {
                                SpeechRecognizer.ERROR_AUDIO -> "Check other apps using the microphone, then tap Answer by voice."
                                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Check your connection, then tap Answer by voice."
                                SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "Wait a moment, then tap Answer by voice."
                                else -> "Tap Answer by voice to retry, or open Speech recognition settings."
                            }
                            val delay = when (error) {
                                SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> 3000L
                                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> 1500L
                                else -> 750L
                            }
                            recover(language, request, recoveries, reason, "$reason (error $error). $help", delay)
                        }
                        else -> fail(request, "Speech recognition stopped (error $error). Tap Answer by voice to retry, or answer on screen.", false)
                    }
                }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            }
            recognizer = SpeechRecognizer.createSpeechRecognizer(context).also { it.setRecognitionListener(listener) }
            timeout = Runnable {
                if (!end()) return@Runnable
                if (microphoneOpened) fail(request, "Listening timed out.", true)
                else recover(language, request, recoveries, "The speech service did not open the microphone.",
                    "The speech service did not open the microphone. Tap Answer by voice to retry, or open Speech recognition settings.", 750L)
            }.also { handler.postDelayed(it, 15_000) }
            recognizer?.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5))
        } catch (_: SecurityException) {
            if (end()) fail(request, "Microphone permission is missing. Allow Cupitor microphone access in Android app permissions, then try again.", false)
        } catch (_: Exception) {
            if (end()) recover(language, request, recoveries, "The speech service could not start.",
                "The speech service could not start. Tap Answer by voice to retry, or open Speech recognition settings.", 750L)
        }
    }

    private fun recover(language: String, request: Int, recoveries: Int, reason: String, finalMessage: String, delay: Long) {
        if (!current(request)) return
        if (recoveries >= MAX_RECOVERIES) { fail(request, finalMessage, false); return }
        onStatus("$reason Retrying microphone (${recoveries + 1}/$MAX_RECOVERIES)…")
        later(delay * (recoveries + 1), request) { begin(language, request, recoveries + 1) }
    }

    private fun fail(request: Int, message: String, countsAsAnswer: Boolean) {
        if (!current(request)) return
        requested = false
        onListening(false)
        if (request == generation && isActive()) onFailure(message, countsAsAnswer)
    }

    fun cancel() {
        generation++ // invalidate before cancel/destroy can trigger callbacks
        requested = false
        pending?.let(handler::removeCallbacks); pending = null
        session.cancel()
        release(cancel = true)
        onListening(false)
    }

    private fun release(cancel: Boolean) {
        timeout?.let(handler::removeCallbacks); timeout = null
        val old = recognizer ?: return
        recognizer = null
        closedAt = SystemClock.uptimeMillis()
        if (cancel) try { old.cancel() } catch (_: Exception) {}
        try { old.destroy() } catch (_: Exception) {}
    }
}
