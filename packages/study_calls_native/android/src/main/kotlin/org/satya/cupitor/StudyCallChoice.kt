package org.satya.cupitor

import java.text.Normalizer
import java.util.Locale

data class StudyCallVoiceChoice(val index: Int, val transcript: String)

/** Number replies and fuzzy labels. Close competitors remain ambiguous rather
 * than allowing a transcription error to silently pick a different option. */
object StudyCallChoice {
    private fun normalize(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFKC)
        .lowercase(Locale.ROOT).replace(Regex("[\\p{P}\\p{S}]"), " ")
        .replace(Regex("\\s+"), " ").trim()

    private val numbers = listOf(
        setOf("1", "one", "first", "en", "ett", "första", "ettan"),
        setOf("2", "two", "second", "två", "tva", "andra", "tvåan"),
        setOf("3", "three", "third", "tre", "tredje", "trean"),
        setOf("4", "four", "fourth", "fyra", "fjärde", "fyran"),
        setOf("5", "five", "fifth", "fem", "femte", "femman"),
        setOf("6", "six", "sixth", "sex", "sjätte", "sexan"),
        setOf("7", "seven", "seventh", "sju", "sjunde", "sjuan"),
        setOf("8", "eight", "eighth", "åtta", "åttonde", "åttan"),
        setOf("9", "nine", "ninth", "nio", "nionde", "nian"),
    )
    private val prefix = Regex("^(?:(?:i choose|i pick|jag väljer|jag svarar) )?(?:option|alternative|number|alternativ|nummer|svarsalternativ)(?: (?:number|nummer))? (.+)$")

    fun numberIndex(text: String): Int = numbers.indexOfFirst { normalize(text) in it }

    fun match(hypotheses: List<String>, choices: List<String>,
              threshold: Double = StudyCallAnswer.DEFAULT_MATCH_THRESHOLD): StudyCallVoiceChoice? {
        if (choices.size !in 2..9) return null
        val labels = choices.map(::normalize)
        val matches = mutableMapOf<Int, String>()
        for (raw in hypotheses.take(5)) {
            val text = normalize(raw)
            if (text.isEmpty()) continue
            val exact = labels.indices.filter { labels[it].isNotEmpty() && labels[it] == text }
            // Label first: for choices [ett, en], saying "en" means the second
            // label, even though Swedish "en" also means the number one.
            if (exact.isNotEmpty()) {
                exact.forEach { matches.putIfAbsent(it, raw.trim().take(500)) }
                continue
            }
            val number = prefix.matchEntire(text)?.groupValues?.get(1) ?: text
            val index = numberIndex(number)
            if (index in choices.indices) {
                matches.putIfAbsent(index, raw.trim().take(500))
                continue
            }
            val ranked = choices.indices.map { it to StudyCallAnswer.similarity(raw, choices[it]) }.sortedByDescending { it.second }
            val best = ranked.first()
            if (best.second + 1e-9 >= threshold) {
                if (ranked.size > 1 && best.second - ranked[1].second < 0.12) return null
                matches.putIfAbsent(best.first, raw.trim().take(500))
            }
        }
        if (matches.size != 1) return null
        return matches.entries.single().let { StudyCallVoiceChoice(it.key, it.value) }
    }
}

/** Android callbacks do not identify their session. A fresh token on every
 * listen/cancel prevents late results from a stopped microphone saving an answer. */
class StudyCallVoiceSession {
    private var generation = 0
    var listening = false
        private set

    fun begin(): Int { generation++; listening = true; return generation }
    fun isCurrent(token: Int) = listening && token == generation
    fun complete(token: Int): Boolean {
        if (!isCurrent(token)) return false
        listening = false
        return true
    }
    fun cancel() { generation++; listening = false }
}
