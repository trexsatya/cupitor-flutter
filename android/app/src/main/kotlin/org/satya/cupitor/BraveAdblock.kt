package org.satya.cupitor

import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.util.Base64
import android.webkit.*
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.WeakHashMap
import java.util.concurrent.Executors

internal interface ChainedWebViewClient { val innerClient: WebViewClient }

/** JNI entry points into the same Brave Rust engine linked by the macOS app. */
internal object BraveNative {
    init { System.loadLibrary("cupitor_adblock") }
    @JvmStatic external fun initialize(directory: String, platform: String): String
    @JvmStatic external fun query(input: String): String
}

internal object BraveAdblock {
    @Volatile var ready = false
        private set
    @Volatile var enabled = true
    private var source = ""
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private data class Registration(var source: String = "", var handler: ScriptHandler? = null)
    private val views = WeakHashMap<WebView, Registration>()

    fun initialize(directory: String, completion: (Map<String, Any?>) -> Unit) {
        worker.execute {
            val result = try {
                val value = JSONObject(BraveNative.initialize(directory, "android"))
                if (value.optBoolean("ready")) {
                    val script = JSONObject(BraveNative.query("{\"op\":\"script\"}")).getString("script")
                    main.post {
                        source = script
                        ready = true
                        views.keys.toList().forEach { install(it) }
                        completion(value.keys().asSequence().associateWith { value.opt(it).takeUnless { item -> item == JSONObject.NULL } })
                    }
                    return@execute
                }
                mapOf("ready" to false, "error" to value.optString("error"))
            } catch (error: Throwable) {
                mapOf("ready" to false, "error" to (error.message ?: error.javaClass.simpleName))
            }
            // Failed updates leave the previous native engine and registrations usable.
            main.post { completion(result) }
        }
    }

    fun install(view: WebView): Boolean {
        val registration = views.getOrPut(view) { Registration() }
        if (!ready) return false
        val earlyScripts = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        view.addJavascriptInterface(PageBridge(earlyScripts), "CupitorBraveNative")
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT) && registration.source != source) {
            registration.handler?.remove()
            registration.handler = WebViewCompat.addDocumentStartJavaScript(view, source, setOf("*"))
            registration.source = source
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.GET_WEB_VIEW_CLIENT)) {
            val client = WebViewCompat.getWebViewClient(view)
            var current: WebViewClient? = client
            var found = false
            repeat(12) {
                if (current is BraveWebViewClient) found = true
                current = (current as? ChainedWebViewClient)?.innerClient
            }
            if (!found) view.webViewClient = BraveWebViewClient(client)
        }
        return true
    }

    class PageBridge(private val managed: Boolean) {
        @JavascriptInterface fun query(input: String): String {
            if (!ready || input.length > 65536) return "{\"ready\":false}"
            return try {
                val request = JSONObject(input)
                if (request.optString("op") !in setOf("status", "page", "selectors", "network")) return "{}"
                if (!enabled && request.optString("op") != "status") return "{}"
                val result = JSONObject(BraveNative.query(input))
                result.put("enabled", enabled).put("managed", managed).toString()
            } catch (_: Exception) { "{}" }
        }
    }

    fun requestType(request: WebResourceRequest): String {
        if (request.isForMainFrame) return "document"
        val headers = request.requestHeaders.orEmpty()
        val destination = headers.entries.firstOrNull { it.key.equals("Sec-Fetch-Dest", true) }?.value
        when (destination) {
            "script", "worker", "sharedworker", "serviceworker" -> return "script"
            "style" -> return "stylesheet"
            "image" -> return "image"
            "font" -> return "font"
            "audio", "video" -> return "media"
            "iframe", "frame", "document" -> return "subdocument"
        }
        val accept = headers.entries.firstOrNull { it.key.equals("Accept", true) }?.value.orEmpty()
        val path = request.url.path.orEmpty().lowercase()
        return when {
            accept.contains("text/html") -> "subdocument"
            accept.contains("text/css") || path.endsWith(".css") -> "stylesheet"
            accept.contains("javascript") || path.endsWith(".js") || path.endsWith(".mjs") -> "script"
            accept.startsWith("image/") || path.matches(Regex(".*\\.(png|jpe?g|gif|webp|svg|avif)$")) -> "image"
            accept.startsWith("font/") || path.matches(Regex(".*\\.(woff2?|ttf|otf)$")) -> "font"
            accept.startsWith("audio/") || accept.startsWith("video/") -> "media"
            headers.keys.any { it.equals("X-Requested-With", true) } || accept.contains("json") -> "xmlhttprequest"
            else -> "other"
        }
    }

    fun response(decision: JSONObject): WebResourceResponse? {
        if (!decision.optBoolean("blocked")) return null
        val redirect = decision.optString("redirect", "")
        if (redirect.startsWith("data:") && redirect.contains(";base64,")) {
            return try {
                val marker = redirect.indexOf(";base64,")
                val mime = redirect.substring(5, marker).substringBefore(';').ifEmpty { "text/plain" }
                val bytes = Base64.decode(redirect.substring(marker + 8), Base64.DEFAULT)
                WebResourceResponse(mime, "utf-8", 200, "OK", mapOf("Access-Control-Allow-Origin" to "*"), ByteArrayInputStream(bytes))
            } catch (_: Exception) { WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(byteArrayOf())) }
        }
        return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(byteArrayOf()))
    }
}

internal class BraveWebViewClient(delegate: WebViewClient) : ForwardingWebViewClient(delegate) {
    @Volatile private var page = ""
    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
        page = url
        super.onPageStarted(view, url, favicon)
    }
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
        if (BraveAdblock.ready && BraveAdblock.enabled && request.url.scheme in listOf("https", "http")) {
            try {
                val origin = request.requestHeaders.entries.firstOrNull { it.key.equals("Referer", true) }?.value ?: page
                val query = JSONObject().put("op", "network").put("url", request.url.toString())
                    .put("source", origin).put("type", BraveAdblock.requestType(request)).put("method", request.method)
                val response = BraveAdblock.response(JSONObject(BraveNative.query(query.toString())))
                if (response != null) return response
            } catch (_: Exception) { /* delegate on malformed requests, never break local media */ }
        }
        return super.shouldInterceptRequest(view, request)
    }
}

/** Preserve Flutter, local-media, renderer, authentication and browser callbacks. */
internal open class ForwardingWebViewClient(final override val innerClient: WebViewClient) : WebViewClient(), ChainedWebViewClient {
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) = innerClient.shouldInterceptRequest(view, request)
    @Suppress("DEPRECATION") override fun shouldInterceptRequest(view: WebView, url: String) = innerClient.shouldInterceptRequest(view, url)
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = innerClient.shouldOverrideUrlLoading(view, request)
    @Suppress("DEPRECATION") override fun shouldOverrideUrlLoading(view: WebView, url: String) = innerClient.shouldOverrideUrlLoading(view, url)
    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) = innerClient.onPageStarted(view, url, favicon)
    override fun onPageFinished(view: WebView, url: String) = innerClient.onPageFinished(view, url)
    override fun onPageCommitVisible(view: WebView, url: String) = innerClient.onPageCommitVisible(view, url)
    override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) = innerClient.doUpdateVisitedHistory(view, url, isReload)
    override fun onLoadResource(view: WebView, url: String) = innerClient.onLoadResource(view, url)
    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) = innerClient.onReceivedError(view, request, error)
    @Suppress("DEPRECATION") override fun onReceivedError(view: WebView, code: Int, description: String, url: String) = innerClient.onReceivedError(view, code, description, url)
    override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) = innerClient.onReceivedHttpError(view, request, response)
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) = innerClient.onReceivedSslError(view, handler, error)
    override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String) = innerClient.onReceivedHttpAuthRequest(view, handler, host, realm)
    override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) = innerClient.onReceivedClientCertRequest(view, request)
    override fun onReceivedLoginRequest(view: WebView, realm: String, account: String?, args: String) = innerClient.onReceivedLoginRequest(view, realm, account, args)
    override fun onFormResubmission(view: WebView, dontResend: Message, resend: Message) = innerClient.onFormResubmission(view, dontResend, resend)
    override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) = innerClient.onScaleChanged(view, oldScale, newScale)
    override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?) = innerClient.onRenderProcessGone(view, detail)
}
