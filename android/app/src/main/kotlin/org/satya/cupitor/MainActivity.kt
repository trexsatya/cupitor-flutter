package org.satya.cupitor

import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.webkit.HttpAuthHandler
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "cupitor/adblock"
        private const val PREFS_NAME = "cupitor_adblock"
        private const val PREFS_CUSTOM_HOSTS = "custom_ad_hosts"

        // Built-in baseline — never modified at runtime.
        private val BUILTIN_AD_HOSTS = setOf(
            "googlesyndication.com",
            "doubleclick.net",
            "googleadservices.com",
            "adservice.google.com",
            "adservice.google.co.uk",
            "pagead2.googlesyndication.com",
            "tpc.googlesyndication.com",
            "adnxs.com",
            "advertising.com",
            "amazon-adsystem.com",
            "ads.yahoo.com",
            "taboola.com",
            "outbrain.com",
            "moatads.com",
            "adsafeprotected.com",
            "scorecardresearch.com",
            "pubads.g.doubleclick.net",
            "static.ads-twitter.com",
            "ads.twitter.com",
            "ads.linkedin.com",
            "googletagservices.com",
            "criteo.com",
            "rubiconproject.com",
            "openx.net",
            "pubmatic.com",
            "contextweb.com",
            "bidswitch.net",
            "casalemedia.com",
        )

        // Subdomain prefixes that strongly indicate an ad/tracking server.
        // Only the leftmost label is checked to avoid false positives on
        // legitimate hosts that happen to contain these strings mid-domain.
        private val AD_SUBDOMAIN_PREFIXES = setOf(
            "ad", "ads", "adserver", "adserve", "adserving", "adtrack",
            "adservice", "adtech", "adnxs", "adsystem", "adnetwork",
            "adexchange", "addelivery", "adchoices",
            "tracker", "tracking", "track",
            "pixel", "beacon", "ping", "collect", "hit", "event",
            "analytics", "telemetry", "metrics", "stat", "stats",
            "spy", "counter", "log", "logs",
        )

        // Path segments that strongly indicate an ad/tracking endpoint.
        // We require the segment to be an entire path component (surrounded by
        // slashes or at the end) to avoid false positives like "/radio/".
        private val AD_PATH_SEGMENTS = setOf(
            "ads", "ad", "adserve", "adserver", "adnxs",
            "banner", "banners", "sponsor", "sponsored",
            "track", "tracking", "tracker",
            "pixel", "beacon", "ping", "collect", "hit",
            "analytics", "telemetry", "stat", "stats",
            "impression", "click", "conversion",
            "promo", "promotion",
        )

        // Well-known legitimate domains that must never be auto-blocked regardless
        // of subdomain or path signals.
        private val NEVER_BLOCK_HOSTS = setOf(
            "youtube.com", "youtu.be", "ytimg.com", "yt3.ggpht.com", "googlevideo.com",
            "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com",
            "ggpht.com", "googletagmanager.com",
            "facebook.com", "fbcdn.net", "instagram.com",
            "twitter.com", "x.com", "twimg.com",
            "reddit.com", "redditmedia.com", "redd.it",
            "github.com", "githubusercontent.com", "githubassets.com",
            "wikipedia.org", "wikimedia.org", "wikpedia.org",
            "cloudflare.com", "cloudfront.net", "fastly.net",
            "akamaized.net", "akamai.net",
            "jsdelivr.net", "unpkg.com",
            "amazon.com", "amazonaws.com", "amazon.co.uk",
            "microsoft.com", "azure.com", "msn.com",
            "apple.com", "icloud.com",
            "netflix.com",
            "stackoverflow.com", "stackexchange.com",
        )
    }

    // Runtime set = built-in + persisted custom hosts. Reads/writes on main thread only.
    private val adHosts: MutableSet<String> = LinkedHashSet(BUILTIN_AD_HOSTS)

    // Channel reference kept so AdBlockWebViewClient can send auto-detected events back to Dart.
    private var adBlockChannel: MethodChannel? = null

    // Whether network-level ad blocking is active (toggled from Dart).
    @Volatile var adBlockEnabled = true

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        loadCustomHosts()
    }

    private fun loadCustomHosts() {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        val saved = prefs.getStringSet(PREFS_CUSTOM_HOSTS, emptySet()) ?: emptySet()
        adHosts.addAll(saved)
    }

    private fun persistCustomHosts() {
        val custom = adHosts - BUILTIN_AD_HOSTS
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            .edit()
            .putStringSet(PREFS_CUSTOM_HOSTS, custom)
            .apply()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        adBlockChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "attach" -> {
                    attachAdBlocker()
                    result.success(null)
                }
                "addHost" -> {
                    val host = call.argument<String>("host")
                    if (host.isNullOrBlank()) { result.error("BAD_ARG", "host required", null); return@setMethodCallHandler }
                    val added = adHosts.add(host.lowercase().trim())
                    if (added) persistCustomHosts()
                    result.success(added)
                }
                "removeHost" -> {
                    val host = call.argument<String>("host")
                    if (host.isNullOrBlank()) { result.error("BAD_ARG", "host required", null); return@setMethodCallHandler }
                    val removed = adHosts.remove(host.lowercase().trim())
                    if (removed) persistCustomHosts()
                    result.success(removed)
                }
                "getHosts" -> result.success(adHosts.toList())
                "getCustomHosts" -> result.success((adHosts - BUILTIN_AD_HOSTS).toList())
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    adBlockEnabled = enabled
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Attach the ad-blocking WebViewClient to the main WebView.
    // Safe to call multiple times — no-ops if already attached.
    // Requires API 26+ to read the existing WebViewClient; on older devices the
    // feature is silently skipped to avoid breaking the navigation delegate.
    // ---------------------------------------------------------------------------
    private fun attachAdBlocker() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        for (webView in allWebViews()) {
            val current = webView.webViewClient
            if (current is AdBlockWebViewClient) continue   // already wrapped
            webView.webViewClient = AdBlockWebViewClient(current)
        }
    }

    /** Depth-first search for ALL WebViews in a view tree. */
    private fun findAllWebViews(view: View, result: MutableList<WebView>) {
        if (view is WebView) { result.add(view); return }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) findAllWebViews(view.getChildAt(i), result)
        }
    }

    /** Collect WebViews from the Activity window and any Dialog windows. */
    private fun allWebViews(): List<WebView> {
        val result = mutableListOf<WebView>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return result
        // Activity window
        findAllWebViews(window.decorView, result)
        // Dialog windows — accessible via the WindowManager's internal list using reflection
        try {
            val wm = windowManager
            val wmGlobalClass = Class.forName("android.view.WindowManagerGlobal")
            val getInstance = wmGlobalClass.getMethod("getInstance")
            val wmGlobal = getInstance.invoke(null)
            val viewsField = wmGlobalClass.getDeclaredField("mViews")
            viewsField.isAccessible = true
            @Suppress("UNCHECKED_CAST")
            val views = viewsField.get(wmGlobal) as? ArrayList<View> ?: return result
            for (v in views) findAllWebViews(v, result)
        } catch (_: Exception) { /* reflection unavailable — activity window WebViews only */ }
        return result
    }

    // ---------------------------------------------------------------------------
    // Delegating WebViewClient that blocks ad-network requests and forwards
    // every other callback to the original Flutter WebViewClient.
    // ---------------------------------------------------------------------------
    private inner class AdBlockWebViewClient(
        private val delegate: WebViewClient
    ) : WebViewClient() {

        // Cached on the main thread in onPageStarted; read safely from background threads.
        @Volatile
        private var currentPageHost: String? = null

        private fun isAdHost(url: String?): Boolean {
            if (url == null) return false
            val host = try {
                Uri.parse(url).host?.lowercase() ?: return false
            } catch (_: Exception) { return false }
            return adHosts.any { blocked -> host == blocked || host.endsWith(".$blocked") }
        }

        private fun emptyResponse() =
            WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))

        private fun emptyJsonResponse() =
            WebResourceResponse(
                "application/json", "utf-8",
                ByteArrayInputStream("{}".toByteArray())
            )

        /**
         * Returns a non-null response to swallow YouTube's ad-reporting endpoints.
         * We return empty JSON so the player doesn't retry on parse failure.
         */
        private fun matchYouTubeAdPath(uri: Uri): Boolean {
            val host = uri.host?.lowercase() ?: return false
            if (!host.endsWith("youtube.com") && !host.endsWith("googlevideo.com")) return false
            val path = uri.path?.lowercase() ?: return false
            return path.startsWith("/api/stats/ads")
                || path.startsWith("/pagead/")
                || path.startsWith("/ptracking")
                || path.startsWith("/api/stats/qoe")
                || path.startsWith("/youtubei/v1/log_event")
        }

        // Returns the eTLD+1-ish registrable host to use as the block key.
        // e.g. "sub.tracker.example.com" → "tracker.example.com" (2 labels).
        // Falls back to the full host if parsing fails.
        private fun registrableHost(host: String): String {
            val labels = host.split('.')
            return if (labels.size >= 2) labels.takeLast(2).joinToString(".") else host
        }

        /**
         * Heuristic scan of a URL that passed the blocklist.
         * Returns the host to auto-block if strong ad/tracking signals are found,
         * or null if the URL looks legitimate.
         *
         * Rules (both must pass to avoid false positives):
         *   1. The leftmost subdomain label is in AD_SUBDOMAIN_PREFIXES, OR
         *      at least two separate path segments are in AD_PATH_SEGMENTS.
         *   2. The request is third-party (host ≠ page host).
         */
        private fun detectAdHost(url: String, pageHost: String?): String? {
            val uri = try { Uri.parse(url) } catch (_: Exception) { return null }
            val host = uri.host?.lowercase() ?: return null

            // Never auto-block the page's own domain
            if (pageHost != null && (host == pageHost || host.endsWith(".$pageHost"))) return null

            // Never auto-block well-known legitimate domains
            val regHost = registrableHost(host)
            if (NEVER_BLOCK_HOSTS.any { regHost == it || regHost.endsWith(".$it") }) return null

            // --- Rule 1: leftmost subdomain label ---
            val leftLabel = host.substringBefore('.')
            val hostSignal = leftLabel in AD_SUBDOMAIN_PREFIXES

            // --- Rule 2: path segments ---
            val pathSegments = (uri.path ?: "")
                .lowercase()
                .split('/')
                .filter { it.isNotBlank() }
            val pathHits = pathSegments.count { it in AD_PATH_SEGMENTS }
            val pathSignal = pathHits >= 2

            if (!hostSignal && !pathSignal) return null

            // Use the registrable host (eTLD+1) as the block key so we block
            // all sub-paths/subdomains of the ad server, not just one endpoint.
            return registrableHost(host)
        }

        // ---- The key interception point ----
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest
        ): WebResourceResponse? {
            if (!adBlockEnabled) return delegate.shouldInterceptRequest(view, request)
            val urlStr = request.url.toString()
            if (isAdHost(urlStr)) return emptyResponse()

            // Block YouTube ad-reporting endpoints (path-based, not host-based)
            if (matchYouTubeAdPath(request.url)) return emptyJsonResponse()

            // Auto-detection: heuristically scan requests that passed the blocklist.
            // shouldInterceptRequest runs on a background thread — use the cached
            // currentPageHost instead of calling view.url (main-thread only).
            val pageHost = currentPageHost
            val detected = detectAdHost(urlStr, pageHost)
            if (detected != null) {
                view.post {
                    val added = adHosts.add(detected)
                    if (added) {
                        persistCustomHosts()
                        // Notify Dart so it can log/display newly detected hosts
                        adBlockChannel?.invokeMethod("onHostDetected", mapOf("host" to detected))
                    }
                }
                return emptyResponse()
            }

            return delegate.shouldInterceptRequest(view, request)
        }

        // ---- Delegate all navigation/lifecycle callbacks to Flutter's client ----
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
            delegate.shouldOverrideUrlLoading(view, request)

        @Suppress("DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView, url: String) =
            delegate.shouldOverrideUrlLoading(view, url)

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            currentPageHost = Uri.parse(url).host?.lowercase()
            delegate.onPageStarted(view, url, favicon)
        }

        override fun onPageFinished(view: WebView, url: String) =
            delegate.onPageFinished(view, url)

        override fun onPageCommitVisible(view: WebView, url: String) =
            delegate.onPageCommitVisible(view, url)

        override fun onReceivedError(
            view: WebView, request: WebResourceRequest, error: WebResourceError
        ) = delegate.onReceivedError(view, request, error)

        @Suppress("DEPRECATION")
        override fun onReceivedError(
            view: WebView, errorCode: Int, description: String, failingUrl: String
        ) = delegate.onReceivedError(view, errorCode, description, failingUrl)

        override fun onReceivedSslError(
            view: WebView, handler: SslErrorHandler, error: SslError
        ) = delegate.onReceivedSslError(view, handler, error)

        override fun onReceivedHttpAuthRequest(
            view: WebView, handler: HttpAuthHandler, host: String, realm: String
        ) = delegate.onReceivedHttpAuthRequest(view, handler, host, realm)

        override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) =
            delegate.onScaleChanged(view, oldScale, newScale)
    }
}
