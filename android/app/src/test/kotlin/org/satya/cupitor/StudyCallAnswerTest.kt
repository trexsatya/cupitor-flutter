package org.satya.cupitor

import org.junit.Assert.*
import org.junit.Test

class StudyCallAnswerTest {
    @Test fun smallTranscriptionErrorsAndWordSpacingAreAccepted() {
        for ((heard, expected) in listOf("en kat" to "en katt", "Stockholn" to "Stockholm",
            "smorgas" to "smörgås", "oversittare" to "översittare", "en vackerdag" to "en vacker dag",
            "  HÖG   KVALITET! " to "hög kvalitet", "libary" to "library")) {
            assertTrue("$heard should match $expected", StudyCallAnswer.textIsCorrect(heard, listOf(expected)))
        }
    }

    @Test fun wrongNumbersNegationsAndShortMeaningChangesAreRejected() {
        for ((heard, expected) in listOf("The code is 1235" to "The code is 1234", "-1" to "1",
            "I do agree with this proposal" to "I do not agree with this proposal",
            "Jag vill ha kaffe" to "Jag vill inte ha kaffe", "en" to "ett", "år" to "är",
            "Gothenburg" to "Stockholm", "" to "anything")) {
            assertFalse("$heard must not match $expected", StudyCallAnswer.textIsCorrect(heard, listOf(expected)))
        }
    }

    @Test fun acceptedVariantsAndMatchingThresholdAreConfigurable() {
        assertTrue(StudyCallAnswer.textIsCorrect("automobile", listOf("car", "automobile")))
        assertTrue(StudyCallAnswer.textIsCorrect("Stockholn", listOf("Stockholm"), 0.8))
        assertFalse(StudyCallAnswer.textIsCorrect("Stockholn", listOf("Stockholm"), 1.0))
        assertTrue(StudyCallAnswer.textIsCorrect("four", listOf("4")))
    }

    @Test fun defaultThreeRetriesMeansFourAttemptsAndStopsAtCorrectAnswer() {
        val retries = StudyCallAnswer.DEFAULT_RETRIES
        assertEquals(3, retries)
        for (attempt in 1..3) assertTrue(StudyCallAnswer.shouldRetry(false, attempt, retries))
        assertFalse(StudyCallAnswer.shouldRetry(false, 4, retries))
        assertFalse(StudyCallAnswer.shouldRetry(true, 1, retries))
        assertFalse(StudyCallAnswer.shouldRetry(null, 1, retries))
        assertFalse(StudyCallAnswer.shouldRetry(false, 1, 0))
        assertTrue(StudyCallAnswer.shouldRetry(false, 10, 10))
        assertFalse(StudyCallAnswer.shouldRetry(false, 11, 10))
    }
}
