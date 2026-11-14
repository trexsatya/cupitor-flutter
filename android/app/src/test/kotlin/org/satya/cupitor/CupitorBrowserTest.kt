package org.satya.cupitor

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 35], manifest = Config.NONE)
class CupitorBrowserTest {
    @Test
    fun captureIsAvailableOnlyOnFilmotPages() {
        assertTrue(CupitorBrowser.isFilmotUrl("https://filmot.com/search/test"))
        assertTrue(CupitorBrowser.isFilmotUrl("https://beta.filmot.com/video/123"))
        for (url in listOf(
            null,
            "https://notfilmot.com/",
            "https://filmot.com.example.org/",
            "https://filmot.com@example.org/",
            "https://example.org/?next=https://filmot.com/",
            "https://accounts.google.com/",
            "https://www.patreon.com/",
        )) {
            assertFalse(url, CupitorBrowser.isFilmotUrl(url))
        }
    }

    @Test
    fun browserAcceptsWebAddressesAndRejectsLocalAndCredentialUrls() {
        assertTrue(CupitorBrowser.isWebUrl("https://example.org/path"))
        assertTrue(CupitorBrowser.isWebUrl("http://localhost:8000/"))
        for (url in listOf("file:///tmp/page.html", "intent://example.org/", "https://user@example.org/", "https:///")) {
            assertFalse(url, CupitorBrowser.isWebUrl(url))
        }
    }
}
