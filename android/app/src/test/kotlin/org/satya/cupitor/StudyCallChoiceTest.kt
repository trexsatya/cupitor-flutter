package org.satya.cupitor

import org.junit.Assert.*
import org.junit.Test

class StudyCallChoiceTest {
    @Test fun numbersAndExplicitOptionPhrasesSelectTheNumberedAlternative() {
        val choices = listOf("red", "blue", "green")
        for (heard in listOf("2", "two", "second", "två", "andra", "option two", "alternativ nummer två", "I choose option two")) {
            assertEquals(heard, 1, StudyCallChoice.match(listOf(heard), choices)!!.index)
        }
    }

    @Test fun exactSwedishArticleLabelsWinOverNumericAliases() {
        assertEquals(1, StudyCallChoice.match(listOf("en"), listOf("ett", "en"))!!.index)
        assertEquals(0, StudyCallChoice.match(listOf("ett"), listOf("ett", "en"))!!.index)
        assertEquals(0, StudyCallChoice.match(listOf("option one"), listOf("ett", "en"))!!.index)
    }

    @Test fun fuzzyLabelsWorkButConflictingOrCloseCandidatesStayAmbiguous() {
        assertEquals(0, StudyCallChoice.match(listOf("Stockholn"), listOf("Stockholm", "Gothenburg"))!!.index)
        assertNull(StudyCallChoice.match(listOf("colur"), listOf("color", "colour")))
        assertNull(StudyCallChoice.match(listOf("red", "blue"), listOf("red", "blue")))
        assertNull(StudyCallChoice.match(listOf("I don't know"), listOf("red", "blue")))
        assertNull(StudyCallChoice.match(listOf("9"), listOf("red", "blue")))
    }

    @Test fun aFinalCallbackCanOnlyCompleteItsOwnCurrentMicrophoneAttempt() {
        val session = StudyCallVoiceSession()
        val cancelled = session.begin()
        session.cancel()
        assertFalse(session.complete(cancelled))
        val old = session.begin()
        val current = session.begin()
        assertFalse(session.complete(old))
        assertTrue(session.complete(current))
        assertFalse(session.complete(current))
        assertFalse(session.listening)
    }
}
