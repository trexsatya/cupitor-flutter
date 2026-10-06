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
import java.io.RandomAccessFile
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "cupitor/adblock"
        private const val YTDLP_CHANNEL = "cupitor/ytdlp"
        private const val MEDIA_KEYS_CHANNEL = "cupitor/mediakeys"
        private const val PERMS_CHANNEL = "cupitor/perms"

        // Arbitrary request code for ActivityCompat.requestPermissions —
        // matched against onRequestPermissionsResult so we route the answer
        // back to the correct pending MethodChannel.Result.
        private const val PERM_REQ_MIC = 4001
        private const val PERM_REQ_CAMERA = 4002
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

    // Kept for the same reason: RenderGuardClient has to reach Dart from a
    // callback, long after configureFlutterEngine's local scope is gone.
    private var permsChannel: MethodChannel? = null

    // Hosts already surfaced to Dart this page-load — prevents re-notifying for the same host.
    // Accessed from both the intercept thread (background) and main thread, so backed by a
    // concurrent set to avoid posting a Runnable for every flagged URL on a busy page.
    // Cleared on each onPageStarted.
    private val notifiedHosts: MutableSet<String> =
        java.util.concurrent.ConcurrentHashMap.newKeySet()

    // Whether network-level ad blocking is active (toggled from Dart).
    @Volatile var adBlockEnabled = true

    // Pending result per in-flight permission request, keyed by request code.
    // Only one per permission can be outstanding at a time — a second request
    // while one is pending is resolved to false immediately so the caller can
    // retry.
    private val pendingPermResults = mutableMapOf<Int, MethodChannel.Result>()

    // Native MediaRecorder session for the manual-entry recorder. We capture
    // through this path (instead of WebView's getUserMedia) because the
    // WebView audio stack races with `speech_to_text` and has been observed
    // to surface `NotReadableError` even when no other app holds the mic.
    // Outputs AAC-in-MP4 directly to the path Dart hands us.
    private var nativeRecorder: android.media.MediaRecorder? = null
    private var nativeRecorderPath: String? = null

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

        // ---- Runtime-permission channel ----
        // Android's `RECORD_AUDIO` is a dangerous permission — declaring it
        // in the manifest is not enough, the user must approve it via the
        // OS prompt. WebView's `onPermissionRequest` (handled in Dart) only
        // controls the per-WebView resource flag; without the OS-level
        // permission `getUserMedia({audio:true})` silently rejects and the
        // recorder appears broken. Dart calls into here to make sure the
        // OS-level grant is in place before granting the WebView request.
        val permsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMS_CHANNEL)
        this.permsChannel = permsChannel
        permsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestMicrophone" -> requestRuntimePermission(
                    android.Manifest.permission.RECORD_AUDIO, PERM_REQ_MIC, result
                )
                "requestCamera" -> requestRuntimePermission(
                    android.Manifest.permission.CAMERA, PERM_REQ_CAMERA, result
                )
                "startNativeRecording" -> {
                    // New API: caller passes `pathStem` (no extension) and the
                    // recorder picks .ogg / .m4a based on the OS's Opus support.
                    // We still accept the legacy `path` key (extension included)
                    // for callers that haven't been updated yet — the recorder
                    // strips the extension before deciding the container.
                    val pathStem = call.argument<String>("pathStem")
                        ?: call.argument<String>("path")?.let {
                            val dot = it.lastIndexOf('.')
                            if (dot > 0) it.substring(0, dot) else it
                        }
                    if (pathStem.isNullOrBlank()) {
                        result.error("BAD_ARG", "pathStem required", null)
                        return@setMethodCallHandler
                    }
                    startNativeRecording(pathStem, result)
                }
                "installFrameScript" -> installFrameScript(
                    call.argument<String>("script") ?: "", result
                )
                "frameScriptStatus" -> frameScriptStatus(result)
                "installRenderGuard" -> installRenderGuard(result)
                "attachLocalMedia" -> attachLocalMedia(call.argument<String>("dir"), result)
                "stopNativeRecording" -> stopNativeRecording(result)
                "cancelNativeRecording" -> cancelNativeRecording(result)
                "isNativeRecording" -> result.success(nativeRecorder != null)
                "lastExitInfo" -> result.success(lastExitInfo())
                "memoryBreakdown" -> result.success(memoryBreakdown())
                "shareText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val chooserTitle = call.argument<String>("chooserTitle") ?: "Share"
                    val subject = call.argument<String>("subject")
                    if (text.isEmpty()) {
                        result.error("BAD_ARG", "text required", null)
                        return@setMethodCallHandler
                    }
                    shareText(text, chooserTitle, subject)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---- Where is the memory actually going? -------------------------------
    //
    // A process dying at ~1 GB RSS tells you the size but not the owner, and
    // guessing the owner from the code has a bad track record. This is the
    // same breakdown `adb shell dumpsys meminfo` prints, read from inside the
    // app so it works on a device where developer options are blocked.
    //
    // Which bucket grows is what identifies the culprit:
    //   native-heap  → a native library (ML Kit / TFLite, audio, youtubedl)
    //   graphics     → GPU textures, Flutter's raster cache, WebView layers
    //   java-heap    → Dart/Java objects
    //   code         → mapped .so / .dex, roughly constant
    // Values are kB, as the platform reports them.
    // Measured for EVERY process the app owns, not just this one. The WebView
    // renderer is a separate process (<package>:sandboxed_process*), and
    // anything the page holds — IndexedDB records read into JS, blobs, big
    // strings — is charged to it, not to us. Sampling only our own pid would
    // therefore report a healthy app while the process that is actually
    // growing goes unseen. getRunningAppProcesses returns only the caller's
    // own processes on modern Android, which is exactly the set we want.
    private fun memoryBreakdown(): List<Map<String, Any?>> {
        val am = getSystemService(android.content.Context.ACTIVITY_SERVICE)
                as? android.app.ActivityManager ?: return emptyList()
        val procs = try {
            am.runningAppProcesses ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
        // Always include ourselves, even if the query above came back empty.
        val byPid = linkedMapOf(android.os.Process.myPid() to (packageName ?: "self"))
        for (p in procs) byPid[p.pid] = p.processName
        val pids = byPid.keys.toIntArray()
        val infos = try {
            am.getProcessMemoryInfo(pids)
        } catch (e: Exception) {
            return emptyList()
        }
        val out = mutableListOf<Map<String, Any?>>()
        for ((i, pid) in pids.withIndex()) {
            val mi = infos?.getOrNull(i) ?: continue
            // getMemoryStat is API 23+, so safe at minSdk 24. It returns
            // decimal strings, and null for a key the platform withholds.
            fun stat(key: String): Int =
                try { mi.getMemoryStat(key)?.toIntOrNull() ?: 0 } catch (e: Exception) { 0 }
            // ApplicationExitInfo reports RSS, the memory summary reports PSS,
            // and they differ by a lot — RSS counts every resident page
            // including shared system libraries, PSS only a proportional
            // share. Reporting PSS alone makes a live sample look tiny next to
            // a crash record and invites a false conclusion. /proc is hidden
            // for other processes on modern Android, so reconstruct RSS from
            // the parts instead: it is the sum of the four resident buckets.
            val rss = mi.totalPrivateDirty + mi.totalPrivateClean +
                      mi.totalSharedDirty + mi.totalSharedClean
            out.add(mapOf(
                "pid" to pid,
                "name" to (byPid[pid] ?: ""),
                "rss" to rss,
                "totalPss" to stat("summary.total-pss"),
                "javaHeap" to stat("summary.java-heap"),
                "nativeHeap" to stat("summary.native-heap"),
                "graphics" to stat("summary.graphics"),
                "code" to stat("summary.code"),
                "privateOther" to stat("summary.private-other"),
            ))
        }
        return out
    }

    // ---- Why did we die last time? ----------------------------------------
    //
    // Some process deaths leave no crash report anywhere. The one that matters
    // here: every WebView in the app shares ONE sandboxed renderer process, and
    // WebViewClient.onRenderProcessGone decides what happens when it dies.
    // Returning false — which is the default, and which webview_flutter_android
    // never overrides — means "crash the app if the renderer crashed, kill it
    // if the system killed the renderer". A kill raises no Java exception and
    // writes no tombstone, so Play Console's crash vitals never hear about it
    // and the app just seems to vanish.
    //
    // ActivityManager is the one place that records the real reason. Reading it
    // at startup is the only way to see these deaths from inside the app.
    // API 30+ only; older platforms get an empty list and no diagnosis.
    private fun lastExitInfo(): List<Map<String, Any?>> {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) {
            return emptyList()
        }
        return exitInfoSinceR()
    }

    @androidx.annotation.RequiresApi(android.os.Build.VERSION_CODES.R)
    private fun exitInfoSinceR(): List<Map<String, Any?>> {
        val am = getSystemService(android.content.Context.ACTIVITY_SERVICE)
                as? android.app.ActivityManager ?: return emptyList()
        // 0 = any pid, 8 = the last eight deaths. The system keeps a bounded
        // ring per package, so this is everything available.
        val records = try {
            am.getHistoricalProcessExitReasons(packageName, 0, 8)
        } catch (e: Exception) {
            return emptyList()
        }
        return records.map { info ->
            mapOf(
                "reason" to info.reason,
                "reasonName" to exitReasonName(info.reason),
                // For REASON_SIGNALED this is the signal number, for
                // REASON_EXIT_SELF the exit status. Meaningless otherwise.
                "status" to info.status,
                "importance" to info.importance,
                "pss" to info.pss,
                "rss" to info.rss,
                "timestamp" to info.timestamp,
                "description" to info.description,
                "processName" to info.processName,
                // The tombstone. Android exposes it ONLY for native crashes
                // and ANRs, and only through here — an app cannot read its own
                // tombstone from /data/tombstones. This is what names the
                // signal and the crashing library, so it is the whole reason
                // a native crash is diagnosable without adb.
                "trace" to traceOf(info),
            )
        }
    }

    /// Raw trace bytes for a native crash or ANR, capped so a huge tombstone
    /// cannot blow up the platform channel. Null for every other exit reason.
    ///
    /// Returned as BYTES on purpose. The two formats here are not the same:
    /// an ANR trace is text, but a native-crash tombstone is a protobuf
    /// (Android 12+ is where native tombstones became readable by the app at
    /// all). Decoding either as a string throws away the other, so hand the
    /// bytes up and let the caller decide how to read them.
    @androidx.annotation.RequiresApi(android.os.Build.VERSION_CODES.R)
    private fun traceOf(info: android.app.ApplicationExitInfo): ByteArray? {
        return try {
            info.traceInputStream?.use { stream ->
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(16 * 1024)
                var total = 0
                while (total < 512 * 1024) {
                    val n = stream.read(buf)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    total += n
                }
                if (total == 0) null else out.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }

    @androidx.annotation.RequiresApi(android.os.Build.VERSION_CODES.R)
    private fun exitReasonName(reason: Int): String = when (reason) {
        android.app.ApplicationExitInfo.REASON_ANR -> "ANR"
        android.app.ApplicationExitInfo.REASON_CRASH -> "CRASH-java"
        android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH-native"
        // The renderer dying can surface as this one: the app depended on a
        // child process that went away.
        android.app.ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        // API 31+. Killed over the app freezer, e.g. a synchronous binder call
        // made to us while we were frozen in the background. Named here rather
        // than left to the `else` branch because it is not rare on modern
        // Android and "reason=14" says nothing to anyone reading the log.
        android.app.ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        android.app.ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        android.app.ApplicationExitInfo.REASON_OTHER -> "OTHER"
        android.app.ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        android.app.ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        android.app.ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        android.app.ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        else -> "reason=$reason"
    }

    // ---- Native MediaRecorder ----
    // start: open AudioRecord through MediaRecorder, write to a
    //        <stem>.<ext> file where the container is chosen from the
    //        platform's Opus support:
    //          API ≥ 29 (Android 10+): OPUS in an OGG container (.ogg)
    //          API < 29:               AAC-LC in MPEG-4 (.m4a)
    //        Returns the actual file path on success, errors otherwise.
    // stop:  finish writing the file and return the path. Returns null if
    //        nothing was recording.
    // cancel: stop without keeping the file; deletes any partial output.
    private fun startNativeRecording(pathStem: String, result: MethodChannel.Result) {
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.RECORD_AUDIO
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION", "RECORD_AUDIO not granted", null); return
        }
        if (nativeRecorder != null) {
            result.error("BUSY", "another recording is already in progress", null); return
        }
        // MediaRecorder(Context) ctor is API 31+; on older platforms the
        // no-arg ctor is still the supported path. Build error-safe.
        val rec = if (android.os.Build.VERSION.SDK_INT >= 31) {
            android.media.MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION")
            android.media.MediaRecorder()
        }
        val useOpus = android.os.Build.VERSION.SDK_INT >= 29
        val path = if (useOpus) "$pathStem.ogg" else "$pathStem.m4a"
        try {
            rec.setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
            if (useOpus) {
                // OPUS/OGG path — the modern, most storage-efficient choice
                // for speech. 24 kbps mono @ 16 kHz is transparent for
                // spoken word and lands at ~3 KB/sec on disk (~180 KB/min).
                rec.setOutputFormat(android.media.MediaRecorder.OutputFormat.OGG)
                rec.setAudioEncoder(android.media.MediaRecorder.AudioEncoder.OPUS)
                rec.setAudioChannels(1)
                rec.setAudioSamplingRate(16_000)
                rec.setAudioEncodingBitRate(24_000)
            } else {
                // API 24–28 fallback: AAC-LC in MPEG-4 (.m4a). Tuned for
                // speech (16 kHz / 32 kbps mono) — ~4 KB/sec on disk.
                rec.setOutputFormat(android.media.MediaRecorder.OutputFormat.MPEG_4)
                rec.setAudioEncoder(android.media.MediaRecorder.AudioEncoder.AAC)
                rec.setAudioChannels(1)
                rec.setAudioSamplingRate(16_000)
                rec.setAudioEncodingBitRate(32_000)
            }
            rec.setOutputFile(path)
            rec.prepare()
            rec.start()
        } catch (e: Exception) {
            try { rec.release() } catch (_: Exception) {}
            // Clean up the half-written file if `setOutputFile` already created it.
            try { java.io.File(path).delete() } catch (_: Exception) {}
            result.error("START_FAILED", e.message ?: e.toString(), null)
            return
        }
        nativeRecorder = rec
        nativeRecorderPath = path
        result.success(path)
    }

    // ---- Document-start script, all frames ---------------------------------
    //
    // runJavaScript evaluates in the main frame only, and a cross-origin
    // iframe cannot be touched from its parent document — so content inside an
    // embedded reader served from another subdomain is unreachable from any
    // page script. WebViewCompat.addDocumentStartJavaScript works below that
    // boundary: it runs the script in every frame, at document start, before
    // the frame's own scripts.
    //
    // Handlers are kept so a re-install replaces rather than stacks.
    /// The agent itself, remembered so a WebView built later can still get it.
    private var frameScript: String? = null

    /// One handler per WebView we have registered on. Weak, because a WebView
    /// that has gone away must not be held alive by this map, and identity
    /// keyed because View does not override equals.
    private val frameScriptHandlers =
        java.util.WeakHashMap<android.webkit.WebView, androidx.webkit.ScriptHandler>()

    private var frameScriptWatching = false
    private var lastFrameScriptScan = 0L

    private fun documentStartSupported(): Boolean =
        androidx.webkit.WebViewFeature.isFeatureSupported(
            androidx.webkit.WebViewFeature.DOCUMENT_START_SCRIPT)

    /**
     * Register the remembered script on every WebView that does not have it.
     *
     * Returns how many were newly registered. Views already carrying it are
     * skipped, so this is cheap to call repeatedly — which is the point, since
     * it runs from a layout listener.
     */
    private fun applyFrameScript(): Int {
        val script = frameScript ?: return 0
        if (!documentStartSupported()) return 0
        val views = mutableListOf<android.webkit.WebView>()
        try {
            collectWebViews(window.decorView, views)
        } catch (_: Exception) { return 0 }
        var added = 0
        for (v in views) {
            if (frameScriptHandlers.containsKey(v)) continue
            try {
                // "*" because an embedded reader can live on any host, and the
                // script itself decides whether a given frame is interesting.
                frameScriptHandlers[v] =
                    androidx.webkit.WebViewCompat.addDocumentStartJavaScript(
                        v, script, setOf("*")
                    )
                added++
            } catch (_: Exception) { /* this view misses out; others may not */ }
        }
        return added
    }

    /**
     * Register on each WebView the moment it enters the view tree.
     *
     * A document-start script only applies to documents that BEGIN after it is
     * registered, so registering has to beat the first navigation. Polling
     * cannot promise that. Layout runs before the first frame is drawn, and
     * again when a dialog adds its own WebView, so this is the earliest point
     * available — and it covers the dialog WebViews, which are built long
     * after startup and which a one-shot install never reached at all.
     */
    private fun watchForNewWebViews() {
        if (frameScriptWatching) return
        frameScriptWatching = true
        try {
            window.decorView.viewTreeObserver.addOnGlobalLayoutListener {
                // Layout is frequent and the scan walks the view tree, so it is
                // throttled. The window is short enough that a WebView added in
                // one layout pass is registered in the next.
                val now = android.os.SystemClock.uptimeMillis()
                if (now - lastFrameScriptScan < 100) return@addOnGlobalLayoutListener
                lastFrameScriptScan = now
                applyFrameScript()
            }
        } catch (_: Exception) { frameScriptWatching = false }
    }

    private fun installFrameScript(script: String, result: MethodChannel.Result) {
        if (script.isBlank()) { result.success("skipped: empty script"); return }
        if (!documentStartSupported()) {
            // Ships with the WebView, not the OS, so an old system WebView on a
            // new Android is possible.
            result.success("unsupported: this WebView has no DOCUMENT_START_SCRIPT")
            return
        }
        if (script != frameScript) {
            // A different script makes every existing registration stale.
            for (h in frameScriptHandlers.values) {
                try { h.remove() } catch (_: Exception) {}
            }
            frameScriptHandlers.clear()
            frameScript = script
        }
        watchForNewWebViews()
        val added = applyFrameScript()
        val total = frameScriptHandlers.size
        result.success(
            if (total > 0) "registered on $added new webview(s), $total total"
            else "armed: no webview yet, will register as one is attached"
        )
    }

    /** How many WebViews currently carry the frame script. */
    private fun frameScriptStatus(result: MethodChannel.Result) {
        // Scan first: the caller is asking because it is waiting to navigate,
        // and a WebView attached since the last layout should count now.
        applyFrameScript()
        result.success(frameScriptHandlers.size)
    }

    private fun collectWebViews(view: android.view.View, out: MutableList<android.webkit.WebView>) {
        if (view is android.webkit.WebView) { out.add(view); return }
        if (view is android.view.ViewGroup) {
            for (i in 0 until view.childCount) collectWebViews(view.getChildAt(i), out)
        }
    }

    // ---- Stacking two WebViewClient wrappers safely ------------------------
    //
    // The app wraps each WebView's client twice, for unrelated reasons: once to
    // block ad hosts, once to survive a dead renderer. Both are installed
    // repeatedly (ad-block on every onPageFinished, the guard on every dialog
    // open), so each must be able to tell whether ITS OWN wrapper is already
    // present. Checking only the outermost client is not enough — the other
    // wrapper is then mistaken for "not mine", and the two re-wrap each other
    // forever: AB(RG(AB(RG(plugin)))) after two navigations, deeper after
    // every one that follows. Exposing the delegate link makes the question
    // answerable about the whole chain instead of just its top.
    private interface ChainedWebViewClient {
        val innerClient: WebViewClient
    }

    private fun chainHas(client: WebViewClient?, cls: Class<*>): Boolean {
        var c: WebViewClient? = client
        // Bounded rather than while(true): a cycle here would hang the UI
        // thread, and no legitimate chain is more than a couple of links.
        var hops = 0
        while (c != null && hops++ < 8) {
            if (cls.isInstance(c)) return true
            c = (c as? ChainedWebViewClient)?.innerClient
        }
        return false
    }

    // ---- Surviving a dead WebView renderer ---------------------------------
    //
    // Every WebView in the app shares ONE sandboxed renderer process. When that
    // process dies — the system reclaiming it under memory pressure, or it
    // crashing on its own — WebViewClient.onRenderProcessGone decides what
    // happens next, and the DEFAULT is to take the whole app down with it.
    // webview_flutter_android subclasses WebViewClient but never overrides
    // that method, so out of the box a renderer death is an unrecoverable
    // native crash in the APP process. That is what the CRASH-native / SIGTRAP
    // records with libwebviewchromium on the stack are.
    //
    // Returning true instead makes the death survivable. Two consequences the
    // caller has to honour:
    //   * The WebView is unusable afterwards. It cannot be reloaded, only
    //     replaced. Dart owns every controller, so Dart does the replacing.
    //   * Tearing the view out of the hierarchy here would be fighting Flutter
    //     for ownership of a platform view, so this deliberately does NOT
    //     remove or destroy it. Disposing the widget on the Dart side is what
    //     releases it, through the path Flutter already knows about.
    //
    // API 26 is the floor for the whole feature: onRenderProcessGone,
    // getWebViewClient() and setRendererPriorityPolicy all arrived there.
    // Below it the guard is a no-op and the old behaviour stands.
    private fun installRenderGuard(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success("unsupported: needs API 26")
            return
        }
        // allWebViews(), not a decorView walk: dialog1 and dialog2 can live in
        // their own windows, and a WebView missed here is one that still takes
        // the app down.
        val views = try {
            allWebViews()
        } catch (e: Exception) {
            result.success("failed to scan views: " + (e.message ?: ""))
            return
        }
        if (views.isEmpty()) {
            // Flutter builds the platform view lazily; the caller retries.
            result.success("no-webview")
            return
        }
        var guarded = 0
        var already = 0
        for (v in views) {
            try {
                // Ask the system to kill something else first. The second
                // argument is what matters for this app: the default waives the
                // renderer's priority the moment the WebView stops being
                // visible, and dialog1 spends most of its life behind something.
                v.setRendererPriorityPolicy(
                    android.webkit.WebView.RENDERER_PRIORITY_IMPORTANT, false
                )
                // Re-wrapping is self-correcting rather than tracked: if the
                // plugin has since set a fresh client on this view, ours is no
                // longer in the chain and we wrap again. Asking about the whole
                // chain — not just the outermost client — is what stops this
                // and the ad-blocker from re-wrapping each other forever.
                val current = v.webViewClient
                if (chainHas(current, RenderGuardClient::class.java)) { already++; continue }
                v.webViewClient = RenderGuardClient(current)
                guarded++
            } catch (e: Exception) {
                // One stubborn view is not worth failing the whole install for.
            }
        }
        result.success("guarded $guarded webview(s), $already already guarded")
    }

    /// Forwards every call to the plugin's own client and adds the one
    /// behaviour it is missing. Delegation is by hand because WebViewClient is
    /// a class, not an interface — there is no proxy to generate. The set below
    /// is exactly what WebViewClientProxyApi overrides, plus the two intercept
    /// hooks, so wrapping changes nothing the plugin can observe.
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.O)
    private inner class RenderGuardClient(
        private val inner: WebViewClient
    ) : WebViewClient(), ChainedWebViewClient {

        override val innerClient: WebViewClient get() = inner

        override fun onRenderProcessGone(
            view: WebView?,
            detail: android.webkit.RenderProcessGoneDetail?
        ): Boolean {
            // didCrash() false means the SYSTEM killed the renderer to reclaim
            // memory. That is the case that used to look like the app vanishing
            // for no reason: no Java exception, no tombstone, nothing in Play
            // Console. Recording which of the two it was is the whole point of
            // reporting it rather than swallowing it.
            val crashed = try { detail?.didCrash() ?: false } catch (e: Exception) { false }
            val priority = try { detail?.rendererPriorityAtExit() ?: -1 } catch (e: Exception) { -1 }
            try {
                permsChannel?.invokeMethod(
                    "onRenderProcessGone",
                    mapOf("didCrash" to crashed, "priorityAtExit" to priority)
                )
            } catch (e: Exception) {
                // If Dart cannot be reached we still must not return false —
                // that would reinstate exactly the crash we are here to stop.
            }
            // true = "handled, do not kill the app".
            return true
        }

        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean =
            inner.shouldOverrideUrlLoading(view, request)

        // Deprecated upstream, but still the path the platform takes on the
        // older API levels this app supports, so it has to be forwarded too.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean =
            inner.shouldOverrideUrlLoading(view, url)

        override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? =
            inner.shouldInterceptRequest(view, request)

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun shouldInterceptRequest(view: WebView?, url: String?): WebResourceResponse? =
            inner.shouldInterceptRequest(view, url)

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) =
            inner.onPageStarted(view, url, favicon)

        override fun onPageFinished(view: WebView?, url: String?) =
            inner.onPageFinished(view, url)

        override fun onPageCommitVisible(view: WebView?, url: String?) =
            inner.onPageCommitVisible(view, url)

        override fun onLoadResource(view: WebView?, url: String?) =
            inner.onLoadResource(view, url)

        override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) =
            inner.doUpdateVisitedHistory(view, url, isReload)

        override fun onFormResubmission(
            view: WebView?, dontResend: android.os.Message?, resend: android.os.Message?
        ) = inner.onFormResubmission(view, dontResend, resend)

        override fun onReceivedError(
            view: WebView?, request: WebResourceRequest?, error: WebResourceError?
        ) = inner.onReceivedError(view, request, error)

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onReceivedError(
            view: WebView?, errorCode: Int, description: String?, failingUrl: String?
        ) = inner.onReceivedError(view, errorCode, description, failingUrl)

        override fun onReceivedHttpError(
            view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?
        ) = inner.onReceivedHttpError(view, request, errorResponse)

        override fun onReceivedHttpAuthRequest(
            view: WebView?, handler: HttpAuthHandler?, host: String?, realm: String?
        ) = inner.onReceivedHttpAuthRequest(view, handler, host, realm)

        override fun onReceivedSslError(
            view: WebView?, handler: SslErrorHandler?, error: SslError?
        ) = inner.onReceivedSslError(view, handler, error)

        override fun onReceivedClientCertRequest(
            view: WebView?, request: android.webkit.ClientCertRequest?
        ) = inner.onReceivedClientCertRequest(view, request)

        override fun onReceivedLoginRequest(
            view: WebView?, realm: String?, account: String?, args: String?
        ) = inner.onReceivedLoginRequest(view, realm, account, args)

        override fun onScaleChanged(view: WebView?, oldScale: Float, newScale: Float) =
            inner.onScaleChanged(view, oldScale, newScale)

        override fun onUnhandledKeyEvent(view: WebView?, event: KeyEvent?) =
            inner.onUnhandledKeyEvent(view, event)
    }

    private fun stopNativeRecording(result: MethodChannel.Result) {
        val rec = nativeRecorder
        if (rec == null) { result.success(null); return }
        val path = nativeRecorderPath
        nativeRecorder = null
        nativeRecorderPath = null
        // stop() can throw RuntimeException("stop failed.") if called too
        // quickly after start (no audio captured yet). Treat that as a
        // cancelled recording — delete the (likely-empty/invalid) file
        // and return null so Dart can surface a clean "nothing recorded".
        try {
            rec.stop()
        } catch (e: RuntimeException) {
            try { rec.release() } catch (_: Exception) {}
            if (!path.isNullOrEmpty()) { try { java.io.File(path).delete() } catch (_: Exception) {} }
            result.success(null)
            return
        }
        try { rec.release() } catch (_: Exception) {}
        result.success(path)
    }

    private fun cancelNativeRecording(result: MethodChannel.Result) {
        val rec = nativeRecorder
        val path = nativeRecorderPath
        nativeRecorder = null
        nativeRecorderPath = null
        if (rec != null) {
            try { rec.stop() } catch (_: Exception) {}
            try { rec.release() } catch (_: Exception) {}
        }
        if (!path.isNullOrEmpty()) { try { java.io.File(path).delete() } catch (_: Exception) {} }
        result.success(null)
    }

    // Fires an Intent.ACTION_SEND chooser so the user can hand the text off
    // to any installed app that accepts plain text — ChatGPT, Claude, Gemini,
    // Bard, Bing, Perplexity, system clipboard managers, notes apps, etc.
    // The chooser title (`chooserTitle`) labels the picker; `subject` is
    // optional and used by apps that expect one (email clients, mostly).
    private fun shareText(text: String, chooserTitle: String, subject: String?) {
        val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(android.content.Intent.EXTRA_TEXT, text)
            if (!subject.isNullOrEmpty()) putExtra(android.content.Intent.EXTRA_SUBJECT, subject)
        }
        val chooser = android.content.Intent.createChooser(send, chooserTitle).apply {
            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try { startActivity(chooser) } catch (_: Exception) { /* no chooser available — silent no-op */ }
    }

    // Returns true via `result` if `permission` is granted (now or after the
    // user accepts the prompt). The OS prompt is async — we stash the result
    // until onRequestPermissionsResult fires and then deliver the answer.
    private fun requestRuntimePermission(
        permission: String, requestCode: Int, result: MethodChannel.Result
    ) {
        val alreadyGranted = androidx.core.content.ContextCompat.checkSelfPermission(
            this, permission
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (alreadyGranted) { result.success(true); return }
        // Another request is in flight — bounce. The caller can retry once
        // the first prompt resolves.
        if (pendingPermResults.containsKey(requestCode)) { result.success(false); return }
        pendingPermResults[requestCode] = result
        androidx.core.app.ActivityCompat.requestPermissions(
            this, arrayOf(permission), requestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val pending = pendingPermResults.remove(requestCode) ?: return
        val ok = grantResults.isNotEmpty() &&
                 grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        pending.success(ok)
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
            // Whole chain, not just the outermost client: the render guard can
            // be sitting on top of an ad-blocker that is already installed, and
            // re-wrapping on that basis stacks a new pair on every navigation.
            if (chainHas(current, AdBlockWebViewClient::class.java)) continue
            webView.webViewClient = AdBlockWebViewClient(current)
        }
    }

    // ---------------------------------------------------------------------------
    // Serving the app's own audio files to the WebView.
    //
    // The background-music bed plays local files through a plain <audio>
    // element, and a page loaded over https cannot reference a file:// URL. So
    // the page asks for the audio over LocalMedia.HOST and this client answers
    // it from the one directory Dart nominates.
    //
    // Dart supplies the directory rather than Kotlin guessing it: the files
    // live under path_provider's application-documents directory, and
    // duplicating that plugin's idea of where that is would be a bug waiting
    // for the day it changes.
    // ---------------------------------------------------------------------------
    @Volatile
    private var localMediaDir: String? = null

    private fun attachLocalMedia(dir: String?, result: MethodChannel.Result) {
        if (dir.isNullOrBlank()) {
            result.error("BAD_ARG", "dir required", null)
            return
        }
        localMediaDir = dir
        // Same floor as the ad-blocker and the render guard: reading a
        // WebView's current client — which wrapping requires — is API 26+.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success("unsupported")
            return
        }
        var attached = 0
        var already = 0
        for (webView in allWebViews()) {
            try {
                val current = webView.webViewClient
                if (chainHas(current, LocalMediaWebViewClient::class.java)) { already++; continue }
                webView.webViewClient = LocalMediaWebViewClient(current)
                attached++
            } catch (_: Exception) {
                // One stubborn view is not worth failing the whole attach for.
            }
        }
        // Wrapping nothing is not success. Flutter builds the platform view
        // lazily, so Dart retries on this — the same contract installRenderGuard
        // uses.
        if (attached == 0 && already == 0) {
            result.success("no-webview")
            return
        }
        result.success("attached $attached webview(s), $already already attached")
    }

    private fun notFoundResponse() =
        WebResourceResponse(
            "text/plain", "utf-8", 404, "Not Found",
            emptyMap(),
            ByteArrayInputStream(ByteArray(0))
        )

    /**
     * Answer a request for one of our own audio files, or null when the
     * request is not ours and should carry on down the chain.
     *
     * Runs on a background thread — `shouldInterceptRequest` always does — so
     * reading from disk here is safe.
     */
    private fun serveLocalMedia(request: WebResourceRequest): WebResourceResponse? {
        val uri = request.url ?: return null
        if (!LocalMedia.HOST.equals(uri.host, ignoreCase = true)) return null

        // From here on the request IS ours, so every failure answers 404
        // rather than returning null. Falling through would send it to the
        // network, and LocalMedia.HOST does not resolve — the page would wait
        // for a DNS failure instead of learning the file is missing.
        val name = LocalMedia.fileNameFromPath(uri.encodedPath) ?: return notFoundResponse()
        val dir = localMediaDir ?: return notFoundResponse()

        return try {
            val base = File(dir)
            val file = File(base, name)
            // Second guard, after LocalMedia's. That one proves the request
            // asked for a bare filename; this one proves the filesystem agrees
            // the result is still inside the directory — a symlink is the case
            // the first guard cannot see.
            val root = base.canonicalPath.trimEnd(File.separatorChar) + File.separatorChar
            if (!file.canonicalPath.startsWith(root)) return notFoundResponse()
            if (!file.isFile || !file.canRead()) return notFoundResponse()

            val size = file.length()
            val mime = LocalMedia.contentTypeFor(name)
            // Header names are case-insensitive; the WebView happens to send
            // "Range" but nothing guarantees it.
            val rangeHeader = request.requestHeaders
                ?.entries?.firstOrNull { it.key.equals("Range", ignoreCase = true) }?.value
            val range = LocalMedia.parseRange(rangeHeader, size)
            val raf = RandomAccessFile(file, "r")
            try {
                if (range == null) {
                    WebResourceResponse(
                        mime, null, 200, "OK",
                        mapOf(
                            "Accept-Ranges" to "bytes",
                            "Content-Length" to size.toString(),
                            "Cache-Control" to "no-store",
                        ),
                        RangeInputStream(raf, size)
                    )
                } else {
                    raf.seek(range.start)
                    WebResourceResponse(
                        mime, null, 206, "Partial Content",
                        mapOf(
                            "Accept-Ranges" to "bytes",
                            "Content-Length" to range.length.toString(),
                            "Content-Range" to "bytes ${range.start}-${range.endInclusive}/$size",
                            "Cache-Control" to "no-store",
                        ),
                        RangeInputStream(raf, range.length)
                    )
                }
            } catch (e: Exception) {
                // The response owns the stream once built; until then the
                // handle is ours to close.
                try { raf.close() } catch (_: Exception) {}
                throw e
            }
        } catch (_: Exception) {
            notFoundResponse()
        }
    }

    // ---------------------------------------------------------------------------
    // Delegating WebViewClient that answers requests for the app's own audio
    // files and forwards everything else.
    //
    // Its own client rather than a branch inside AdBlockWebViewClient: that one
    // returns to its delegate as its first act when ad-blocking is switched
    // off, and background music must not stop working because of an unrelated
    // setting.
    // ---------------------------------------------------------------------------
    private inner class LocalMediaWebViewClient(
        private val delegate: WebViewClient
    ) : WebViewClient(), ChainedWebViewClient {

        override val innerClient: WebViewClient get() = delegate

        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest
        ): WebResourceResponse? =
            serveLocalMedia(request) ?: delegate.shouldInterceptRequest(view, request)

        // ---- Everything else goes straight through ----
        // Whichever client is outermost is the only one Android calls, and this
        // wrapper can end up outermost, so the navigation delegate has to be
        // forwarded rather than left to WebViewClient's defaults.
        override fun onRenderProcessGone(
            view: WebView?, detail: android.webkit.RenderProcessGoneDetail?
        ): Boolean = delegate.onRenderProcessGone(view, detail)

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
            delegate.shouldOverrideUrlLoading(view, request)

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun shouldOverrideUrlLoading(view: WebView, url: String) =
            delegate.shouldOverrideUrlLoading(view, url)

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) =
            delegate.onPageStarted(view, url, favicon)

        override fun onPageFinished(view: WebView, url: String) =
            delegate.onPageFinished(view, url)

        override fun onPageCommitVisible(view: WebView, url: String) =
            delegate.onPageCommitVisible(view, url)

        override fun onReceivedError(
            view: WebView, request: WebResourceRequest, error: WebResourceError
        ) = delegate.onReceivedError(view, request, error)

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onReceivedError(
            view: WebView, errorCode: Int, description: String?, failingUrl: String?
        ) = delegate.onReceivedError(view, errorCode, description, failingUrl)

        override fun onReceivedSslError(
            view: WebView, handler: SslErrorHandler, error: SslError
        ) = delegate.onReceivedSslError(view, handler, error)

        override fun onReceivedHttpAuthRequest(
            view: WebView, handler: HttpAuthHandler, host: String, realm: String
        ) = delegate.onReceivedHttpAuthRequest(view, handler, host, realm)

        override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) =
            delegate.onScaleChanged(view, oldScale, newScale)

        // Forwarded for parity with RenderGuardClient rather than because Dart
        // listens today: this wrapper is attached regardless of any setting,
        // so it must never be the reason a callback stops arriving.
        override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) =
            delegate.doUpdateVisitedHistory(view, url, isReload)

        override fun onLoadResource(view: WebView?, url: String?) =
            delegate.onLoadResource(view, url)

        override fun onFormResubmission(
            view: WebView?, dontResend: android.os.Message?, resend: android.os.Message?
        ) = delegate.onFormResubmission(view, dontResend, resend)

        override fun onReceivedHttpError(
            view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?
        ) = delegate.onReceivedHttpError(view, request, errorResponse)

        override fun onReceivedClientCertRequest(
            view: WebView?, request: android.webkit.ClientCertRequest?
        ) = delegate.onReceivedClientCertRequest(view, request)

        override fun onReceivedLoginRequest(
            view: WebView?, realm: String?, account: String?, args: String?
        ) = delegate.onReceivedLoginRequest(view, realm, account, args)
    }

    /** Depth-first search for ALL WebViews in a view tree. */
    private fun findAllWebViews(view: View, result: MutableCollection<WebView>) {
        if (view is WebView) { result.add(view); return }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) findAllWebViews(view.getChildAt(i), result)
        }
    }

    /**
     * Collect WebViews from the Activity window and any Dialog windows.
     *
     * A set, because the two sources overlap: the Activity's decorView is
     * itself one of WindowManagerGlobal's views, so every WebView in the
     * Activity window is reached twice. View does not override equals, so
     * this dedupes by identity, which is what we want. Callers only ever
     * wrap-if-not-already, so duplicates did no harm — but they doubled the
     * counts in the messages those callers report, which is actively
     * misleading when the count is the thing you are trying to read.
     */
    private fun allWebViews(): List<WebView> {
        val result = LinkedHashSet<WebView>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return result.toList()
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
            val views = viewsField.get(wmGlobal) as? ArrayList<View> ?: return result.toList()
            for (v in views) findAllWebViews(v, result)
        } catch (_: Exception) { /* reflection unavailable — activity window WebViews only */ }
        return result.toList()
    }

    // ---------------------------------------------------------------------------
    // Delegating WebViewClient that blocks ad-network requests and forwards
    // every other callback to the original Flutter WebViewClient.
    // ---------------------------------------------------------------------------
    private inner class AdBlockWebViewClient(
        private val delegate: WebViewClient
    ) : WebViewClient(), ChainedWebViewClient {

        override val innerClient: WebViewClient get() = delegate

        // Forwarded because this wrapper can end up OUTSIDE the render guard,
        // and whichever client is outermost is the only one Android calls. Not
        // forwarding it would leave the guard installed but unreachable — the
        // app would still die on a renderer death, with nothing to show why.
        @androidx.annotation.RequiresApi(Build.VERSION_CODES.O)
        override fun onRenderProcessGone(
            view: WebView?, detail: android.webkit.RenderProcessGoneDetail?
        ): Boolean = delegate.onRenderProcessGone(view, detail)

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
