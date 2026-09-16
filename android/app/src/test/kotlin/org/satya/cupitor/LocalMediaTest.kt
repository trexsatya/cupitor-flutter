package org.satya.cupitor

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The two pieces of local-media serving worth proving rather than eyeballing:
 * the guard that decides which file a request may have, and the range parser
 * that lets `<audio>` loop and seek.
 */
class LocalMediaFileNameTest {

    @Test
    fun `accepts a bare filename`() {
        assertEquals("kalinka.mp3", LocalMedia.fileNameFromPath("/cupitor-music/kalinka.mp3"))
    }

    @Test
    fun `decodes a percent-encoded name`() {
        assertEquals("My Song (live).m4a",
            LocalMedia.fileNameFromPath("/cupitor-music/My%20Song%20(live).m4a"))
    }

    @Test
    fun `keeps a literal plus rather than reading it as a space`() {
        // encodeURIComponent writes a literal `+` as `%2B`; URLDecoder would
        // otherwise turn a raw one into a space and rename the file.
        assertEquals("a+b.mp3", LocalMedia.fileNameFromPath("/cupitor-music/a%2Bb.mp3"))
    }

    @Test
    fun `refuses a path that is not ours`() {
        assertNull(LocalMedia.fileNameFromPath("/other/kalinka.mp3"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music"))
        assertNull(LocalMedia.fileNameFromPath(null))
    }

    @Test
    fun `refuses an empty name`() {
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/."))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/.."))
    }

    @Test
    fun `refuses anything that is not a bare filename`() {
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/../databases/tags.db"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/sub/kalinka.mp3"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music//etc/passwd"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/a%5Cb.mp3"))
    }

    @Test
    fun `refuses an escape that only appears once decoded`() {
        // This is the case a guard running before decoding would wave through.
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/..%2F..%2Fdatabases%2Ftags.db"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/%2E%2E%2Fsecrets"))
        assertNull(LocalMedia.fileNameFromPath("/cupitor-music/a%00.mp3"))
    }

    @Test
    fun `names its content types and falls back to octet-stream`() {
        assertEquals("audio/mpeg", LocalMedia.contentTypeFor("a.mp3"))
        assertEquals("audio/mp4", LocalMedia.contentTypeFor("a.M4A"))
        assertEquals("audio/ogg", LocalMedia.contentTypeFor("a.opus"))
        assertEquals("audio/flac", LocalMedia.contentTypeFor("a.flac"))
        assertEquals("application/octet-stream", LocalMedia.contentTypeFor("a.txt"))
        assertEquals("application/octet-stream", LocalMedia.contentTypeFor("noextension"))
    }
}

class LocalMediaRangeTest {

    private val size = 1000L

    @Test
    fun `open-ended range runs to the end of the file`() {
        assertEquals(LocalMedia.Range(0, 999), LocalMedia.parseRange("bytes=0-", size))
        assertEquals(LocalMedia.Range(500, 999), LocalMedia.parseRange("bytes=500-", size))
    }

    @Test
    fun `closed range is inclusive at both ends`() {
        val r = LocalMedia.parseRange("bytes=100-199", size)
        assertEquals(LocalMedia.Range(100, 199), r)
        assertEquals(100L, r!!.length)
    }

    @Test
    fun `suffix range counts back from the end`() {
        assertEquals(LocalMedia.Range(500, 999), LocalMedia.parseRange("bytes=-500", size))
        // Asking for more than the file holds gets the whole file, not a
        // negative start.
        assertEquals(LocalMedia.Range(0, 999), LocalMedia.parseRange("bytes=-5000", size))
    }

    @Test
    fun `clamps an end past the last byte`() {
        assertEquals(LocalMedia.Range(900, 999), LocalMedia.parseRange("bytes=900-99999", size))
    }

    @Test
    fun `a single byte is a range of length one`() {
        // The probe request a media element sends first.
        val r = LocalMedia.parseRange("bytes=0-0", size)
        assertEquals(LocalMedia.Range(0, 0), r)
        assertEquals(1L, r!!.length)
    }

    @Test
    fun `tolerates whitespace inside the spec`() {
        assertEquals(LocalMedia.Range(0, 10), LocalMedia.parseRange("bytes= 0 - 10", size))
        assertEquals(LocalMedia.Range(0, 999), LocalMedia.parseRange("  bytes=0-  ", size))
    }

    @Test
    fun `serves the whole file when the range cannot be satisfied`() {
        assertNull(LocalMedia.parseRange("bytes=1000-", size))
        assertNull(LocalMedia.parseRange("bytes=5000-6000", size))
        assertNull(LocalMedia.parseRange("bytes=200-100", size))
        assertNull(LocalMedia.parseRange("bytes=-0", size))
    }

    @Test
    fun `serves the whole file for a malformed header`() {
        assertNull(LocalMedia.parseRange(null, size))
        assertNull(LocalMedia.parseRange("", size))
        assertNull(LocalMedia.parseRange("items=0-10", size))
        assertNull(LocalMedia.parseRange("bytes=", size))
        assertNull(LocalMedia.parseRange("bytes=abc-def", size))
        assertNull(LocalMedia.parseRange("bytes=0-10,20-30", size))
    }

    @Test
    fun `serves the whole file when the file is empty`() {
        assertNull(LocalMedia.parseRange("bytes=0-", 0))
    }
}

/**
 * The stream is the one piece that actually hands bytes to the WebView, so
 * its boundaries are checked against a real file.
 */
class RangeInputStreamTest {

    private fun tempFile(): java.io.File {
        val f = java.io.File.createTempFile("range", ".bin")
        f.deleteOnExit()
        f.writeBytes(ByteArray(100) { it.toByte() })
        return f
    }

    @Test
    fun `reads exactly the window it was given`() {
        val raf = java.io.RandomAccessFile(tempFile(), "r")
        raf.seek(10)
        val s = RangeInputStream(raf, 5)
        assertArrayEquals(byteArrayOf(10, 11, 12, 13, 14), s.readBytes())
        assertEquals(-1, s.read())
        s.close()
    }

    @Test
    fun `single-byte reads stop at the boundary`() {
        val raf = java.io.RandomAccessFile(tempFile(), "r")
        raf.seek(98)
        val s = RangeInputStream(raf, 2)
        assertEquals(98, s.read())
        assertEquals(99, s.read())
        assertEquals(-1, s.read())
        assertEquals(0, s.available())
        s.close()
    }

    @Test
    fun `a bulk read never runs past the window`() {
        val raf = java.io.RandomAccessFile(tempFile(), "r")
        raf.seek(0)
        val s = RangeInputStream(raf, 3)
        val buf = ByteArray(50)
        assertEquals(3, s.read(buf, 0, 50))
        assertEquals(-1, s.read(buf, 0, 50))
        s.close()
    }

    @Test
    fun `a zero-length window is empty from the start`() {
        val raf = java.io.RandomAccessFile(tempFile(), "r")
        val s = RangeInputStream(raf, 0)
        assertEquals(-1, s.read())
        assertEquals(-1, s.read(ByteArray(8), 0, 8))
        s.close()
    }
}
