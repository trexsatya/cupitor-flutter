package org.satya.cupitor

import java.text.Normalizer
import java.util.Locale

/** Local, deterministic marking. Accepted spellings/synonyms come from the
 * question, rather than guessing what an arbitrary answer might mean. */
object StudyCallAnswer {
    const val DEFAULT_RETRIES = 3
    const val MAX_RETRIES = 10
    const val DEFAULT_MATCH_THRESHOLD = 0.8

    fun normalize(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFKC)
        .lowercase(Locale.ROOT).trim().replace(Regex("\\s+"), " ")
        .trimEnd('.', '!', '?').trimEnd()

    private val numberTokens = Regex("[+-]?\\d+(?:[.,]\\d+)?")
    private val wordTokens = Regex("[\\p{L}]+(?:['’][\\p{L}]+)?")
    private val negations = setOf("not", "no", "never", "without", "don't", "dont", "doesn't", "doesnt",
        "isn't", "isnt", "can't", "cant", "cannot", "won't", "wont", "didn't", "didnt",
        "inte", "ej", "icke", "aldrig", "ingen", "inget", "inga", "utan")

    private fun negationCount(text: String) = wordTokens.findAll(text).count { it.value.replace('’', '\'') in negations }
    private fun folded(char: Char) = Normalizer.normalize(char.toString(), Normalizer.Form.NFD)
        .replace(Regex("\\p{M}"), "")

    /** Small transcription errors are tolerated, but a changed number or
     * missing negation is never just a spelling error. Short words stay exact
     * because a one-letter change can reverse their meaning. */
    fun similarity(answer: String, expected: String): Double {
        val a = normalize(answer)
        val b = normalize(expected)
        if (a.isEmpty() || b.isEmpty()) return 0.0
        if (a == b) return 1.0
        if (Regex("[1-9]").matches(b) && a.matches(Regex("[\\p{L} ]+")) &&
            StudyCallChoice.numberIndex(a) == b.toInt() - 1) return 1.0
        if (numberTokens.findAll(a).map { it.value.replace(',', '.') }.toList() !=
            numberTokens.findAll(b).map { it.value.replace(',', '.') }.toList()) return 0.0
        if (negationCount(a) != negationCount(b)) return 0.0
        val x = a.replace(" ", "")
        val y = b.replace(" ", "")
        if (x == y) return 1.0
        if (minOf(x.length, y.length) < 4) return 0.0
        val foldedX = x.map(::folded)
        val foldedY = y.map(::folded)
        var previous = DoubleArray(y.length + 1) { it.toDouble() }
        for (i in x.indices) {
            val current = DoubleArray(y.length + 1)
            current[0] = (i + 1).toDouble()
            for (j in y.indices) {
                val substitution = when {
                    x[i] == y[j] -> 0.0
                    foldedX[i] == foldedY[j] -> 0.25
                    else -> 1.0
                }
                current[j + 1] = minOf(current[j] + 1, previous[j + 1] + 1, previous[j] + substitution)
            }
            previous = current
        }
        return (1.0 - previous[y.length] / maxOf(x.length, y.length)).coerceIn(0.0, 1.0)
    }

    fun textIsCorrect(answer: String, accepted: List<String>, threshold: Double = DEFAULT_MATCH_THRESHOLD): Boolean =
        accepted.any { similarity(answer, it) + 1e-9 >= threshold }

    fun shouldRetry(correct: Boolean?, attempts: Int, maxRetries: Int): Boolean =
        correct == false && attempts < 1 + maxRetries
}

data class StudyCallResponse(val correct: Boolean?, val retry: Boolean, val attempts: Int, val maxAttempts: Int)
