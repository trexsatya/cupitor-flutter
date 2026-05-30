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
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.KeyEvent
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "cupitor/adblock"
        private const val YTDLP_CHANNEL = "cupitor/ytdlp"
        private const val MEDIA_KEYS_CHANNEL = "cupitor/mediakeys"
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

    // Hosts already surfaced to Dart this page-load — prevents re-notifying for the same host.
    // Accessed from both the intercept thread (background) and main thread, so backed by a
    // concurrent set to avoid posting a Runnable for every flagged URL on a busy page.
    // Cleared on each onPageStarted.
    private val notifiedHosts: MutableSet<String> =
        java.util.concurrent.ConcurrentHashMap.newKeySet()

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
                "flushCookies" -> {
                    // WebView cookies are flushed periodically; force a flush here
                    // (called on app pause) so logins survive a force-kill before
                    // the next periodic write.
                    try {
                        android.webkit.CookieManager.getInstance().flush()
                    } catch (_: Exception) { /* best-effort */ }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ---- yt-dlp channel (bundles Python + yt-dlp via youtubedl-android) ----
        val ytdlpChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YTDLP_CHANNEL)
        ytdlpChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> initYtdlp(result)
                "listTracks" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("BAD_ARG", "url required", null)
                    } else {
                        listTracks(url, result)
                    }
                }
                "downloadSubtitle" -> {
                    val url = call.argument<String>("url")
                    val lang = call.argument<String>("lang")
                    val kind = call.argument<String>("kind") ?: ""
                    if (url.isNullOrBlank() || lang.isNullOrBlank()) {
                        result.error("BAD_ARG", "url and lang required", null)
                    } else {
                        downloadSubtitle(url, lang, kind, result)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ---- media-keys channel ----
        // Lets Dart (a) activate / deactivate our MediaSession, (b) push the
        // current playback state into the system so lockscreen / BT car / etc
        // reflect what's actually playing. Native fires `onKey` back at Dart
        // when the user presses play/pause/next/prev on a headset.
        val mediaKeysChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_KEYS_CHANNEL)
        this.mediaKeysChannel = mediaKeysChannel
        mediaKeysChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    setMediaSessionActive(active)
                    result.success(null)
                }
                "setState" -> {
                    val playing = call.argument<Boolean>("playing") ?: false
                    val title = call.argument<String>("title")
                    val artist = call.argument<String>("artist")
                    setMediaSessionState(playing, title, artist)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---------------------------------------------------------------------------
    // MediaSession — captures wired/Bluetooth headset media buttons while a
    // YouTube iframe is playing inside dialog1. The session is only kept
    // active while Dart explicitly enables it (i.e. while the language page
    // is loaded), so we don't steal media keys from other apps the rest of
    // the time. Callbacks forward to Dart via `onKey`; Dart in turn dispatches
    // a `cupitorMediaKey` CustomEvent into the page so the page can choose
    // custom behavior (replay previous video, etc.).
    // ---------------------------------------------------------------------------
    private var mediaSession: MediaSessionCompat? = null
    private var mediaKeysChannel: MethodChannel? = null
    private var mediaSessionActive = false
    private var lastPlaying = false
    private var lastTitle: String? = null
    private var lastArtist: String? = null

    private fun ensureMediaSession(): MediaSessionCompat {
        mediaSession?.let { return it }
        val session = MediaSessionCompat(this, "CupitorMediaSession")
        // Allow the session to receive media buttons + transport controls.
        session.setFlags(
            MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
            MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        session.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() { dispatchKey("play") }
            override fun onPause() { dispatchKey("pause") }
            override fun onSkipToNext() { dispatchKey("next") }
            override fun onSkipToPrevious() { dispatchKey("previous") }
            override fun onFastForward() { dispatchKey("fast_forward") }
            override fun onRewind() { dispatchKey("rewind") }
            override fun onStop() { dispatchKey("stop") }
            override fun onMediaButtonEvent(intent: android.content.Intent): Boolean {
                // Cover the raw KEYCODE path too — some Bluetooth headsets send
                // multi-function clicks that the framework doesn't route to the
                // typed callbacks above (e.g. play_pause toggle).
                val key = intent.getParcelableExtra<KeyEvent>(android.content.Intent.EXTRA_KEY_EVENT)
                if (key != null && key.action == KeyEvent.ACTION_DOWN) {
                    when (key.keyCode) {
                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                        KeyEvent.KEYCODE_HEADSETHOOK -> { dispatchKey("play_pause"); return true }
                        KeyEvent.KEYCODE_MEDIA_PLAY -> { dispatchKey("play"); return true }
                        KeyEvent.KEYCODE_MEDIA_PAUSE -> { dispatchKey("pause"); return true }
                        KeyEvent.KEYCODE_MEDIA_NEXT -> { dispatchKey("next"); return true }
                        KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { dispatchKey("previous"); return true }
                        KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { dispatchKey("fast_forward"); return true }
                        KeyEvent.KEYCODE_MEDIA_REWIND -> { dispatchKey("rewind"); return true }
                        KeyEvent.KEYCODE_MEDIA_STOP -> { dispatchKey("stop"); return true }
                    }
                }
                return super.onMediaButtonEvent(intent)
            }
        })
        // A non-zero state with at least one action is required for headsets
        // to consider this session "playing" and route buttons here. We update
        // it again every time Dart pushes new playback state.
        session.setPlaybackState(buildPlaybackState(playing = false))
        mediaSession = session
        return session
    }

    private fun buildPlaybackState(playing: Boolean): PlaybackStateCompat {
        val actions = (
            PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
            PlaybackStateCompat.ACTION_FAST_FORWARD or
            PlaybackStateCompat.ACTION_REWIND or
            PlaybackStateCompat.ACTION_STOP
        )
        val state = if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
        return PlaybackStateCompat.Builder()
            .setActions(actions)
            // Position is unknown without a callback per-second; report 0 with
            // 1x speed so the system doesn't try to extrapolate.
            .setState(state, 0L, 1.0f)
            .build()
    }

    private fun setMediaSessionActive(active: Boolean) {
        runOnUiThread {
            if (active) {
                val session = ensureMediaSession()
                if (!mediaSessionActive) {
                    session.isActive = true
                    mediaSessionActive = true
                }
            } else {
                mediaSession?.let {
                    if (mediaSessionActive) {
                        it.isActive = false
                        mediaSessionActive = false
                    }
                }
            }
        }
    }

    private fun setMediaSessionState(playing: Boolean, title: String?, artist: String?) {
        runOnUiThread {
            val session = ensureMediaSession()
            lastPlaying = playing
            lastTitle = title ?: lastTitle
            lastArtist = artist ?: lastArtist
            session.setPlaybackState(buildPlaybackState(playing = playing))
            val md = MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, lastTitle ?: "Cupitor")
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, lastArtist ?: "")
                .build()
            session.setMetadata(md)
        }
    }

    private fun dispatchKey(key: String) {
        runOnUiThread {
            try {
                mediaKeysChannel?.invokeMethod("onKey", mapOf("key" to key))
            } catch (_: Throwable) {}
        }
    }

    override fun onDestroy() {
        try {
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Throwable) {}
        mediaSession = null
        mediaSessionActive = false
        super.onDestroy()
    }

    // ---------------------------------------------------------------------------
    // yt-dlp helpers (Android side). The library bundles a Python interpreter
    // and yt-dlp itself, exposed via a synchronous JNI API that we wrap in
    // suspending IO calls so we don't block the Flutter main thread.
    // ---------------------------------------------------------------------------
    private val ytdlpScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    @Volatile
    private var ytdlpInitialized = false

    private fun initYtdlp(result: MethodChannel.Result) {
        if (ytdlpInitialized) { result.success(true); return }
        ytdlpScope.launch {
            try {
                withContext(Dispatchers.IO) { ensureYtdlpInit() }
                result.success(true)
            } catch (t: Throwable) {
                // YoutubeDLException's top-level message is the generic "failed to
                // initialize" — the real reason (ABI mismatch, missing libpython,
                // disk full, etc.) is in the cause chain. Walk it so Dart sees it.
                android.util.Log.e("Cupitor/ytdlp", "init failed", t)
                result.error("INIT_FAILED", describeThrowable(t), null)
            }
        }
    }

    private fun describeThrowable(t: Throwable): String {
        val parts = mutableListOf<String>()
        var cur: Throwable? = t
        val seen = mutableSetOf<Throwable>()
        while (cur != null && cur !in seen) {
            seen.add(cur)
            parts.add("${cur::class.java.simpleName}: ${cur.message ?: "(no message)"}")
            cur = cur.cause
        }
        // Include a trimmed stacktrace so unfamiliar failures surface a file:line.
        val firstFrame = t.stackTrace.firstOrNull()?.toString()
        if (firstFrame != null) parts.add("at $firstFrame")
        return parts.joinToString(" → ")
    }

    /// Idempotent. `YoutubeDL.init()` itself short-circuits on subsequent
    /// calls, but we wrap with our own flag so we don't pay the dispatcher
    /// hop / check on every call.
    private fun ensureYtdlpInit() {
        if (ytdlpInitialized) return
        synchronized(this) {
            if (ytdlpInitialized) return
            YoutubeDL.init(application)
            ytdlpInitialized = true
        }
    }

    /// Returns `{title, tracks: [{languageCode, name, kind}]}`. ASR tracks
    /// are tagged with `kind: "asr"`. We can't read subtitles off VideoInfo
    /// directly (the field is commented out in the upstream mapper), so we
    /// shell out yt-dlp with `--write-info-json` and parse the dump file.
    private fun listTracks(url: String, result: MethodChannel.Result) {
        ytdlpScope.launch {
            try {
                val infoJson = withContext(Dispatchers.IO) {
                    ensureYtdlpInit()
                    val outDir = File(cacheDir, "ytinfo-${System.currentTimeMillis()}").apply { mkdirs() }
                    try {
                        val req = YoutubeDLRequest(url).apply {
                            addOption("--skip-download")
                            addOption("--write-info-json")
                            addOption("-o", "${outDir.absolutePath}/info")
                        }
                        YoutubeDL.execute(req)
                        val jsonFile = outDir.listFiles { f -> f.name.endsWith(".info.json") }?.firstOrNull()
                            ?: throw RuntimeException("yt-dlp wrote no info.json")
                        jsonFile.readText()
                    } finally {
                        outDir.deleteRecursively()
                    }
                }
                val info = org.json.JSONObject(infoJson)
                val tracks = mutableListOf<Map<String, Any>>()
                info.optJSONObject("subtitles")?.let { subs ->
                    subs.keys().forEach { lang ->
                        tracks.add(mapOf(
                            "languageCode" to lang,
                            "name" to lang,
                            "kind" to "",
                        ))
                    }
                }
                info.optJSONObject("automatic_captions")?.let { auto ->
                    auto.keys().forEach { lang ->
                        tracks.add(mapOf(
                            "languageCode" to lang,
                            "name" to "$lang (auto-generated)",
                            "kind" to "asr",
                        ))
                    }
                }
                result.success(mapOf(
                    "title" to info.optString("title", ""),
                    "tracks" to tracks,
                ))
            } catch (t: Throwable) {
                android.util.Log.e("Cupitor/ytdlp", "listTracks failed", t)
                result.error("LIST_FAILED", describeThrowable(t), null)
            }
        }
    }

    /// Downloads the caption track via `yt-dlp --write-subs / --write-auto-subs`,
    /// preferring json3, falling back to vtt. Returns `{body, format}` so the
    /// Dart caller can dispatch to the correct parser.
    private fun downloadSubtitle(
        url: String, lang: String, kind: String, result: MethodChannel.Result,
    ) {
        ytdlpScope.launch {
            try {
                val payload = withContext(Dispatchers.IO) {
                    ensureYtdlpInit()
                    val outDir = File(cacheDir, "ytsub-${System.currentTimeMillis()}").apply { mkdirs() }
                    try {
                        val req = YoutubeDLRequest(url).apply {
                            addOption("--skip-download")
                            if (kind == "asr") addOption("--write-auto-subs")
                            else addOption("--write-subs")
                            addOption("--sub-langs", lang)
                            // yt-dlp picks the first available from this slash-list.
                            addOption("--sub-format", "json3/vtt/best")
                            addOption("-o", "${outDir.absolutePath}/sub")
                        }
                        YoutubeDL.execute(req)
                        val files = outDir.listFiles { f -> f.name.startsWith("sub") }
                            ?: emptyArray()
                        if (files.isEmpty()) {
                            throw RuntimeException("yt-dlp wrote no subtitle file " +
                                "(language '$lang'${if (kind == "asr") " (auto)" else ""} may not exist for this video)")
                        }
                        // Prefer json3 if multiple formats slipped through.
                        val file = files.sortedBy {
                            if (it.name.endsWith(".json3")) 0
                            else if (it.name.endsWith(".vtt")) 1
                            else 2
                        }.first()
                        val format = when {
                            file.name.endsWith(".json3") -> "json3"
                            file.name.endsWith(".vtt") -> "vtt"
                            else -> "unknown"
                        }
                        mapOf("body" to file.readText(), "format" to format)
                    } finally {
                        outDir.deleteRecursively()
                    }
                }
                result.success(payload)
            } catch (t: Throwable) {
                android.util.Log.e("Cupitor/ytdlp", "downloadSubtitle failed", t)
                result.error("DOWNLOAD_FAILED", describeThrowable(t), null)
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
            // Do NOT block /api/stats/qoe or /youtubei/v1/log_event — those carry
            // non-ad player events too, and blocking them freezes the player.
            return path.startsWith("/api/stats/ads")
                || path.startsWith("/pagead/")
                || path.startsWith("/ptracking")
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

            // Heuristic detection: surface candidate ad hosts to Dart so the user can
            // *choose* to block them via the SnackBar. We do NOT block the request and
            // do NOT add to the blocklist here — auto-blocking caused too many false
            // positives. The user must explicitly confirm via "Block it".
            // shouldInterceptRequest runs on a background thread — use the cached
            // currentPageHost instead of calling view.url (main-thread only).
            val pageHost = currentPageHost
            val detected = detectAdHost(urlStr, pageHost)
            // Dedupe on this (background) thread so we only hop to main once per new host,
            // even when a page fires hundreds of matching requests.
            if (detected != null && notifiedHosts.add(detected)) {
                view.post {
                    adBlockChannel?.invokeMethod("onHostDetected", mapOf("host" to detected))
                }
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
            notifiedHosts.clear()
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
