package org.satya.cupitor

import android.app.Activity
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 35], manifest = Config.NONE)
class BraveAdblockTest {
    private fun request(path: String, headers: Map<String, String> = emptyMap(), main: Boolean = false) = object : WebResourceRequest {
        override fun getUrl() = Uri.parse("https://media.example/$path")
        override fun isForMainFrame() = main
        override fun isRedirect() = false
        override fun hasGesture() = false
        override fun getMethod() = "GET"
        override fun getRequestHeaders() = headers
    }

    @Test fun requestTypesUseWebViewMetadataBeforeFileExtensions() {
        assertEquals("document", BraveAdblock.requestType(request("watch", main = true)))
        assertEquals("script", BraveAdblock.requestType(request("asset", mapOf("sec-fetch-dest" to "script"))))
        assertEquals("subdocument", BraveAdblock.requestType(request("frame.js", mapOf("Sec-Fetch-Dest" to "iframe"))))
        assertEquals("media", BraveAdblock.requestType(request("videoplayback", mapOf("Accept" to "video/mp4"))))
        assertEquals("xmlhttprequest", BraveAdblock.requestType(request("player", mapOf("Accept" to "application/json"))))
        assertEquals("stylesheet", BraveAdblock.requestType(request("main.css")))
    }

    @Test fun redirectsReturnTheEngineResourceWithoutContactingTheAdServer() {
        val allowed = BraveAdblock.response(JSONObject("""{"blocked":false}"""))
        assertNull(allowed)
        val blocked = BraveAdblock.response(JSONObject("""{"blocked":true}"""))!!
        assertEquals(0, blocked.data.readBytes().size)
        val redirect = BraveAdblock.response(JSONObject("""{"blocked":true,"redirect":"data:application/json;base64,e30="}"""))!!
        assertEquals("application/json", redirect.mimeType)
        assertEquals("{}", redirect.data.bufferedReader().readText())
        assertEquals("*", redirect.responseHeaders["Access-Control-Allow-Origin"])
    }

    @Test fun forwardingPreservesLocalResourceAndNavigationDelegates() {
        val view = WebView(Robolectric.buildActivity(Activity::class.java).setup().get())
        val resource = WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(byteArrayOf(42)))
        var starts = 0
        val delegate = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) = resource
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
            override fun onPageStarted(view: WebView, url: String, icon: android.graphics.Bitmap?) { starts++ }
        }
        val wrapper = BraveWebViewClient(delegate)
        assertSame(delegate, wrapper.innerClient)
        // The engine is not initialized in host unit tests; delegation must work.
        assertSame(resource, wrapper.shouldInterceptRequest(view, request("content")))
        assertTrue(wrapper.shouldOverrideUrlLoading(view, request("content")))
        wrapper.onPageStarted(view, "https://media.example/", null)
        assertEquals(1, starts)
        view.destroy()
    }
}
