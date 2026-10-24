package org.satya.cupitor

import android.content.Context
import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale

/** Call-language commands are separate from answer grading and its retry budget. */
object StudyCallControls {
    const val DEFAULT_PAUSE_SECONDS = 3.0
    const val MAX_PAUSE_SECONDS = 120.0
    const val PAUSE_KEY = "repetition_pause_seconds"
    enum class Command { WAIT, CONTINUE, REPEAT }
    private data class Words(val wait: List<String>, val go: List<String>, val repeat: List<String>)
    private val languages = mapOf(
        "sv" to Words(listOf("vänta", "pausa"), listOf("kör", "fortsätt"), listOf("igen", "en gång till", "upprepa")),
        "en" to Words(listOf("wait", "pause"), listOf("go", "continue", "resume"), listOf("again", "once more", "repeat")),
        "es" to Words(listOf("espera", "pausa"), listOf("continúa", "sigue"), listOf("otra vez", "repite")),
        "fr" to Words(listOf("attends", "pause"), listOf("continue", "reprends"), listOf("encore", "répète")),
        "de" to Words(listOf("warte", "pause"), listOf("weiter", "fortfahren"), listOf("noch einmal", "wiederholen")),
        "hi" to Words(listOf("रुको", "रुकिए"), listOf("चलो", "जारी रखो"), listOf("फिर से", "दोबारा")),
        "el" to Words(listOf("περίμενε", "παύση"), listOf("συνέχισε", "πάμε"), listOf("ξανά", "άλλη μία φορά")),
    )
    val supportedLanguages get() = languages.keys.toList()

    fun validate(args: Map<*, *>): Double? {
        if (!args.containsKey(PAUSE_KEY)) return null
        val value = (args[PAUSE_KEY] as? Number)?.toDouble() ?: error("bad_timing")
        check(value.isFinite() && value in 0.0..MAX_PAUSE_SECONDS) { "bad_timing" }
        return value
    }

    fun defaults(context: Context): Map<String, Any> = mapOf(PAUSE_KEY to
        context.getSharedPreferences("study_calls", Context.MODE_PRIVATE)
            .getFloat(PAUSE_KEY, DEFAULT_PAUSE_SECONDS.toFloat()).toDouble())

    fun pauseMillis(context: Context, row: JSONObject): Long =
        (row.optDouble(PAUSE_KEY, defaults(context)[PAUSE_KEY] as Double)
            .coerceIn(0.0, MAX_PAUSE_SECONDS) * 1000).toLong()

    private fun code(language: String) = Locale.forLanguageTag(language).language
    private fun normalized(text: String, language: String): String {
        val value = StudyCallAnswer.normalize(text).replace(Regex("[\\p{P}\\p{S}]"), " ")
            .replace(Regex("\\s+"), " ").trim()
        // Hindi vowel signs carry meaning; do not strip them as Latin accents.
        return if (code(language) == "hi") value else Normalizer.normalize(value, Normalizer.Form.NFD)
            .replace(Regex("\\p{M}"), "")
    }

    fun command(transcript: String, language: String, answers: List<String> = emptyList()): Command? {
        val words = languages[code(language)] ?: return null
        val text = normalized(transcript, language)
        if (text.isEmpty() || answers.any { normalized(it, language) == text }) return null
        val commands = mapOf(Command.WAIT to words.wait, Command.CONTINUE to words.go, Command.REPEAT to words.repeat)
        val exact = commands.filterValues { values -> values.any { normalized(it, language) == text } }.keys
        if (exact.size == 1) return exact.single()
        // Whole phrases only. Short commands stay exact so "ingen" cannot mean "igen".
        return commands.filterValues { values -> values.any {
            val phrase = normalized(it, language)
            phrase.length >= 8 && text.length >= 8 && StudyCallAnswer.similarity(text, phrase) >= 0.9
        } }.keys.singleOrNull()
    }

    fun hint(language: String): String {
        val words = languages[code(language)] ?: return "Use Pause, Continue and Read again on screen."
        return "Voice commands: “${words.wait.first()}” = pause; “${words.go.first()}” = continue; " +
            words.repeat.take(2).joinToString(" / ") { "“$it”" } + " = repeat. Say commands while the microphone is listening."
    }
}
