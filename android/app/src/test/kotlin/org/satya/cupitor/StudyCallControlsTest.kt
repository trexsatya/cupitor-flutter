package org.satya.cupitor

import org.junit.Assert.*
import org.junit.Test

class StudyCallControlsTest {
    @Test fun commandsFollowTheCallLanguageAndTolerateAccentsAndLongPhraseTypos() {
        val wait = StudyCallControls.Command.WAIT
        val go = StudyCallControls.Command.CONTINUE
        val again = StudyCallControls.Command.REPEAT
        for ((language, phrases) in mapOf(
            "sv-SE" to listOf(" VÄNTA! ", "kor", "en gång til"),
            "en-GB" to listOf("pause", "resume", "once more"),
            "es-MX" to listOf("espera", "continua", "otra vez"),
            "fr-FR" to listOf("attends", "continue", "répète"),
            "de-DE" to listOf("warte", "weiter", "noch einmal"),
            "hi-IN" to listOf("रुको", "चलो", "फिर से"),
            "el-GR" to listOf("περίμενε", "συνέχισε", "ξανά"))) {
            assertEquals(wait, StudyCallControls.command(phrases[0], language))
            assertEquals(go, StudyCallControls.command(phrases[1], language))
            assertEquals(again, StudyCallControls.command(phrases[2], language))
        }
        assertEquals(again, StudyCallControls.command("igen", "sv"))
        assertNull(StudyCallControls.command("igen", "en-US"))
        assertNull(StudyCallControls.command("again", "sv-SE"))
        assertNull(StudyCallControls.command("again", "zz"))
    }

    @Test fun commandsAreWholePhrasesAndExactAnswersTakePriority() {
        for (word in listOf("ingen", "väntar", "Jag säger igen", "please don't wait", ""))
            assertNull(word, StudyCallControls.command(word, "sv-SE"))
        assertNull(StudyCallControls.command("IGEN!", "sv-SE", listOf("igen", "aldrig")))
        assertNull(StudyCallControls.command("vänta", "sv-SE", listOf("vänta")))
    }
}
