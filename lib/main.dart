import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform, File, Directory;
import 'dart:math' as math;
import 'dart:ui' show DartPluginRegistrant;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'local_music.dart';
import 'save_file.dart';
import 'package:flutter/foundation.dart'
    show compute, debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
// Not re-exported by speech_to_text.dart; shares the prefix so error types
// read the same as the rest of the plugin's API.
import 'package:speech_to_text/speech_recognition_error.dart' as stt;
import 'speech_hub.dart';
import 'caption_capture.dart';
import 'video_note.dart';
import 'lookup_video_hold.dart';
import 'page_loading.dart';
import 'page_cursor.dart';
import 'translate_detail.dart';
import 'ai_prompt.dart';
import 'youtube_urls.dart';
import 'mac_webview.dart';
import 'history_store.dart';
import 'history_screen.dart';
import 'speech_session.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart' as mlkit;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:workmanager/workmanager.dart';
import 'yt_dlp_service.dart';
import 'eink_mode.dart';
import 'epub_reader.dart';
import 'db.dart';
import 'global_search.dart';
import 'global_search_screen.dart';
import 'lookup_exclusions.dart';
import 'memory_manager.dart';
import 'page_zoom.dart';
import 'scroll_diagnostics.dart';
import 'search_index.dart';
import 'notif/notif_bridge.dart';
import 'notif/notif_channel.dart';
import 'notif/notification_channel.dart';
import 'notif/notif_runtime.dart';
import 'notif/notif_settings.dart';
import 'notif/notif_timer.dart';
import 'notif/notification_manager.dart';
import 'playlist_service.dart';
import 'profile_service.dart';
import 'tag_browser.dart';
import 'capture_meta.dart';
import 'media_store.dart';
import 'tag_capture.dart';
import 'tag_filter.dart';
import 'tag_settings.dart';
import 'text_transform.dart';

/// WorkManager entry point (Android periodic safety net, spec §Delivery:
/// re-arms the window and sweeps missed fires ~every 30 min even if alarms
/// were dropped by an OEM battery killer).
@pragma('vm:entry-point')
void notifWorkmanagerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      tzdata.initializeTimeZones();
      try {
        final zoneName = await FlutterTimezone.getLocalTimezone()
            .timeout(const Duration(seconds: 2));
        tz.setLocalLocation(tz.getLocation(zoneName));
      } catch (_) {}
      await NotifSettings.init();
      await notifChannel.init(NotifCallbacks(
        onOpened: (_) async {},
        onAction: (_, __) async {},
      ));
      await notifService.sweep();
      return true;
    } catch (e) {
      debugPrint('notif worker failed: $e');
      return false; // let WorkManager retry
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hydrate the E-ink toggle from SharedPreferences before the first
  // frame so `einkMode.value` is correct when the shell + any restored
  // route (EPUB reader) build. Fire-and-forget — the default (`true`)
  // is a safe starting value if prefs read is still in flight.
  await initEinkMode();
  // Load user-defined URL patterns that opt out of word-lookup /
  // sentence-tagging JS injection. Must land before the first
  // `onPageFinished` so the guard in `_injectJs` sees the real list.
  await LookupExclusions.init();
  // Browsing history, so the URL bar can suggest from the first keystroke
  // rather than after a first page load.
  await HistoryStore.init();
  // Open the global-search full-text index and honour the user's
  // configured cap before the first search runs.
  await SearchIndex.init();
  // Notifications: waking-hour math and (Plan 2) zonedSchedule both need the
  // device zone. Fallback to UTC keeps the feature alive with shifted windows
  // rather than crashing.
  tzdata.initializeTimeZones();
  try {
    final zoneName = await FlutterTimezone.getLocalTimezone().timeout(const Duration(seconds: 2));
    tz.setLocalLocation(tz.getLocation(zoneName));
  } catch (e) {
    debugPrint('tz init failed, staying on UTC: $e');
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Workmanager().initialize(notifWorkmanagerDispatcher);
    await Workmanager().registerPeriodicTask(
      'cupitor-notif-sweep', 'notifSweep',
      frequency: const Duration(minutes: 30),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }
  // Hide both system bars for maximum reading area, but rely on
  // `immersiveSticky` so the user can swipe from any edge to transiently
  // reveal them (status bar top, back / home / recents bottom). They
  // auto-hide again after a few seconds. This is the standard Android
  // immersive UX — no custom in-app gesture needed.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WebView Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: WebViewExample(),
    );
  }
}

class WebViewExample extends StatefulWidget {
  @override
  WebViewExampleState createState() => WebViewExampleState();
}

class WebViewExampleState extends State<WebViewExample> with WidgetsBindingObserver {
  // NOT final: a renderer death makes the live WebView permanently unusable,
  // and the only recovery is a brand-new controller. See
  // [_recreateAfterRendererDeath].
  late WebViewController _controller;

  /// Rebuilds [_controller] from scratch against [initialUrl].
  ///
  /// Held as a closure rather than extracted into a method because the
  /// construction cascade closes over a dozen locals from the SharedPreferences
  /// block that creates it; capturing it in place keeps that wiring in one
  /// piece and out of the class surface.
  void Function(String initialUrl)? _rebuildMainController;

  /// Last URL that actually finished loading in the main WebView.
  ///
  /// Needed because [_urlController] holds whatever the user may be halfway
  /// through TYPING, and a rebuild has to navigate somewhere loadable.
  String? _lastLoadedUrl;
  WebViewController? dialogController;
  final TextEditingController _urlController = TextEditingController(text: 'https://google.com');
  /// Owned here rather than left to the TextField, because
  /// [RawAutocomplete] needs the same node to know when to show and hide
  /// its suggestion list.
  final FocusNode _urlFocusNode = FocusNode();

  /// True once the user has arrowed off the first suggestion.
  ///
  /// A URL bar must load what you typed when you press Enter, so the
  /// highlight is only honoured after you have moved it. [RawAutocomplete]
  /// would otherwise select the first suggestion on every Enter, quietly
  /// replacing a typed address with a guess.
  bool _urlSuggestionHighlightMoved = false;

  /// Set by [RawAutocomplete]'s onSelected, so an Enter that resolved to a
  /// suggestion doesn't then also load the field text on top of it.
  bool _urlSuggestionPicked = false;
  String _dialogUrl = 'https://trexsatya.github.io/language.html';
  final List<String> _languages = ['sv', 'es'];
  final Map<String, String> _languageParams = {'sv': 'swedish', 'es': 'spanish'};
  String _selectedLanguage = 'sv';
  bool _isControllerReady = false;
  List<String> _bookmarks = [];
  Map<String, String> _bookmarkNames = {};
  int _pageZoomLevel = 0; // each step ≈ 15% on top of 1.0, clamped to [-4, 10]
  // Scroll probe (lib/scroll_diagnostics.dart). Persisted so it survives the
  // app restart that a wedged WebView often prompts, and re-injected on every
  // page load while armed — you turn it on when a page won't scroll, drag on
  // the stuck area, then read Tools ▸ View snippet logs.
  bool _scrollDiagEnabled = false;
  // Minimize state for dialog webviews — when true, the dialog was dismissed via
  // the Minimize button and can be restored from the main screen. The controllers
  // stay alive so the page state (scroll, form input) survives.
  bool _dialog1Minimized = false;
  bool _dialog1EverMinimized = false; // Track if dialog1 has ever been minimized
  // Is dialog1 currently presented on the Navigator stack? Used to suppress
  // duplicate showDialog pushes from re-entrant calls — e.g. voice input
  // fired from inside the open dialog already updates the live WebView via
  // runJavaScript, so it must not also push a fresh dialog route on top.
  bool _dialog1Visible = false;
  // The page whose videos were paused for the open dialog1 (see
  // _holdVideosForLookup); they play again when dialog1 closes.
  WebViewController? _lookupHoldController;

  // Multiple dialog2 instances - each link opens a new dialog
  Map<String, WebViewController> _dialog2Controllers = {};
  Map<String, ValueNotifier<String?>> _dialog2ErrorNotifiers = {};
  Map<String, String> _dialog2Urls = {};
  Set<String> _minimizedDialog2s = {};
  Set<String> _everMinimizedDialog2s = {}; // Track dialogs that have ever been minimized
  // ---- Wiktionary "collect words" feature ----
  // When ON: clicks on the Wiktionary page are intercepted — links don't
  // navigate, and the clicked word is appended to _wiktCollectedWords (joined
  // by '|' when copied out). Global so a single list spans multiple open
  // Wiktionary dialogs, persisted to SharedPreferences across sessions.
  final ValueNotifier<bool> _wiktCollectMode = ValueNotifier(false);
  final ValueNotifier<List<String>> _wiktCollectedWords = ValueNotifier(<String>[]);
  String _currentDialogText = '';
  // ---- Sentence-tagging feature ----
  // _tagCaptureToggleVisible: floating capture chip is on-screen.
  // _tagCaptureArmed: next word tap will capture (chip is in "active" state).
  // Both default off; toggled from Tools drawer and the chip itself.
  // _tagFilterTagIds: in-memory filter set (per spec, not persisted).
  // _pendingTagExtend: single-slot Completer for the JS extend round-trip;
  //   the capture sheet awaits this between Prev/Next button presses.
  bool _tagCaptureToggleVisible = false;
  bool _tagCaptureArmed = false;
  Offset _tagCaptureChipPos = const Offset(-1, -1);
  // Floating "note at this moment" button over video pages. Switched on from
  // the Tools drawer; shown only while the page has a video.
  bool _videoNoteEnabled = false;
  // Page fullscreen is kept inside the main screen so the floating chips stay
  // on top of it. macOS: the page's own element is pinned over the WebView
  // (kInPageFullscreenJs). Android: the WebView's fullscreen view is drawn
  // here instead of on a route of its own.
  bool _macPageFullscreen = false;
  Widget? _androidFullscreenView;
  OnHideCustomWidgetCallback? _hideAndroidFullscreen;
  bool get _webFullscreen =>
      _macPageFullscreen || _androidFullscreenView != null;
  bool _videoNoteHasVideo = false;
  Offset _videoNoteChipPos = const Offset(-1, -1);
  // Floating button that opens the study dialog straight into fullscreen.
  // Shown unless switched off (Tools drawer, or a long press on it).
  bool _studyFsChipEnabled = true;
  // Where the exit-fullscreen button sits inside the fullscreen study dialog.
  Offset _dialog1FsExitPos = const Offset(-1, -1);
  Offset _studyFsChipPos = const Offset(-1, -1);
  late final VideoPresencePoller _videoNotePoller = VideoPresencePoller(
    probe: () => _controller.runJavaScriptReturningResult(kHasVideoJs),
    onChange: (has) {
      if (mounted) setState(() => _videoNoteHasVideo = has);
    },
  );
  Set<int> _tagFilterTagIds = <int>{};
  bool _tagMasksVisible = false;
  bool _tagTransformsEnabled = true;
  // 'block' (default) or 'document'. See sentence_tag.js for semantics.
  String _tagSegmentationScope = 'block';
  Completer<ExtendResult>? _pendingTagExtend;
  bool _tagDbReady = false;
  String? _cachedRemoteSnippet;
  final Set<String> _handledPdfUrls = {};
  bool _isTextView = false;
  bool _isShowingOurHtml = false;
  bool _isExtractingPdf = false;
  String? _currentPdfUrl;
  String? _extractedPdfHtml;
  String _lastStartedUrl = '';
  bool _isEinkMode = einkMode.value;
  // "Save page HTML…": strip Cupitor's own additions from the saved file.
  // Off by default — the page exactly as it stands is the usual ask.
  bool _savePageStrip = false;
  // Notifier + filters now live in `eink_mode.dart` so screens opened
  // via a fresh route (EPUB reader) read the same value as this shell.
  // `_isEinkMode` mirrors `einkMode.value` for local setState paths
  // (Icon in the tools sheet, main WebView) and is updated in the same
  // onChanged as the notifier so they never desync.
  // In-memory buffer for console output captured from the injected remote
  // snippet. Lives until the app process exits — no persistence.
  final List<String> _snippetLogs = [];
  final ValueNotifier<int> _snippetLogVersion = ValueNotifier(0);
  static const int _kSnippetLogCap = 500;
  bool _showToolbar = false;
  bool _showAppBar = true;
  // Drives the toolbar's spinner while the main page loads.
  final PageLoading _pageLoading = PageLoading();
  // Platforms whose top app bar auto-hides on a timer and toggles via
  // double-tap / long-press. Mac mirrors Android so both feel identical.
  bool get _autoHideAppBar => Platform.isAndroid || Platform.isMacOS;
  String? _githubToken;
  int _pdfTextFontSize = 15;
  bool _showFindBar = false;
  bool _urlBarFocused = false;
  String _pdfSelectedText = '';
  // The one process-wide recognizer. Reached through SpeechHub so the
  // singleton assumption is expressed in code rather than in a comment.
  stt.SpeechToText get _speech => SpeechHub.speech;
  bool _isListening = false;
  // Mirror of _isListening for widgets in showDialog routes (which the outer
  // setState() doesn't reach).
  final ValueNotifier<bool> _isListeningNotifier = ValueNotifier(false);
  // Long-press-to-dictate mode: keeps the speech recognizer alive (auto-
  // restarting across the package's per-utterance windows), accumulating
  // transcript until the user taps again to stop.
  bool _continuousVoiceActive = false;
  final StringBuffer _continuousTranscript = StringBuffer();
  String _continuousPartial = '';
  // Transcript of the in-flight one-shot listen. Used to be a local captured
  // by _toggleVoiceInput's onStatus closure; it has to outlive that closure
  // now that status routing lives in _onSpeechStatus.
  String _voiceLastWords = '';
  // Our stake in the shared recognizer's callbacks. See SpeechHub for why
  // registering closures via initialize() cannot work.
  late final SpeechHubListener _speechHubListener = SpeechHubListener(
    onSpeechStatus: _onSpeechStatus,
    onSpeechError: _onSpeechError,
    onSpeechLost: _onSpeechLost,
  );
  // Dictation driven by the webapp over the `SpeechBridge` channel
  // (docs/speech-bridge-spec.md). The session owns the rid routing; these
  // timers are the host-side safety nets described in §5.2.
  final SpeechSession _sttSession = SpeechSession();
  Timer? _sttWatchdog;
  Timer? _sttDoneDebounce;
  DateTime? _sttListenStartedAt;
  DateTime? _sttQuietSince;
  // The native MediaRecorder holds the mic exclusively while it runs, and
  // MainActivity exposes no way to ask. Mirror its state here so a dictation
  // request can refuse rather than silently record nothing.
  bool _nativeRecordingActive = false;
  // A long-press capture was cut short by the app being backgrounded; show
  // what was heard once the user is actually looking at the screen again.
  bool _pendingVoiceResumeDialog = false;
  final TextEditingController _findController = TextEditingController();
  int? _pendingScrollToPage;
  int? _pendingPdfPage;
  // Scroll position cache: URL → scrollY or pdfPage (max 50 entries, persisted)
  Map<String, double> _scrollPositions = {};
  static const int _maxScrollEntries = 50;
  String? _prevPageUrl; // URL of the page we're navigating away from
  PdfViewerController? _pdfViewerController;
  double _pdfFitZoom = 0.0;
  int _pdfZoomLevel = 0;
  // Tracks Android main-frame navigations to detect the second onNavigationRequest
  // call that the download listener makes when WebView can't render a response
  // (e.g. application/pdf). First call = normal navigation; second call = download trigger.
  final Set<String> _androidPendingUrls = {};
  final ValueNotifier<String?> _dialogErrorNotifier = ValueNotifier(null);
  // Fullscreen toggle for dialog1. Notifier (not bare field) so the showDialog
  // route — which lives outside the outer State's setState scope — rebuilds.
  final ValueNotifier<bool> _dialog1FullscreenNotifier = ValueNotifier(false);
  // Language-app ↔ Cupitor bridge for the notification feature (spec:
  // docs/superpowers/specs/2026-07-27-notifications-design.md §Bridge).
  // Permission/exact-alarm/action capabilities are backed by the real
  // delivery layer (Plan 2) via notifChannel/notifService.
  late final NotifBridge _notifBridge = NotifBridge(
    dao: () => CupitorDb.instance.notifDao(),
    activeProfileId: () => ProfileService.currentId,
    emit: _emitNotifEvent,
    capabilities: () async => NotifCapabilities(
      supported: await CupitorDb.instance.isReady(),
      permission: await notifChannel.permissionStatus(),
      exactAlarms: await notifChannel.exactAlarmsAllowed(),
      actions: notifChannel.supportsActions,
      platform: defaultTargetPlatform.name,
    ),
    requestPermission: () async {
      final r = await notifChannel.requestPermission();
      await notifService.rearm(); // permission may have just been granted
      return r;
    },
    window: () => NotifSettings.window,
    now: () => tz.TZDateTime.now(tz.local),
    onMutated: () => notifService.rearm(),
  );
  // Best-effort desktop/web delivery: no OS wake there, so an in-process
  // timer periodically sweeps while the app is open (spec §Platform
  // specifics). Started conditionally in initState.
  late final NotifSweepTimer _notifTimer =
      NotifSweepTimer(sweep: _sweepThenPush);
  // Web Speech Synthesis bridge for dialog1. The Android WebView does not
  // implement window.speechSynthesis, so the dictionary page's TTS calls go
  // through a JS-side polyfill that posts here. We speak one utterance at a
  // time via flutter_tts and fire start/end JS events back into the page so
  // utterance.onstart / .onend work as the page expects.
  FlutterTts? _dialog1Tts;
  final List<Map<String, dynamic>> _dialog1TtsQueue = [];
  int? _dialog1TtsActiveJsId;
  bool _dialog1TtsBusy = false;
  static const _adBlockChannel = MethodChannel('cupitor/adblock');
  // Headset / Bluetooth media-key bridge. Native (MediaSessionCompat) sends
  // play/pause/next/prev events here; we forward each as a `cupitorMediaKey`
  // CustomEvent into dialog1's WebView so the language page can run custom
  // playback behavior (replay previous video, etc.). The page can also push
  // its current playing state back via the `MediaState` JS channel so the
  // lockscreen and Bluetooth car UI show the right title.
  static const _mediaKeysChannel = MethodChannel('cupitor/mediakeys');
  // Runtime-permissions bridge. Android's `RECORD_AUDIO` is a *dangerous*
  // permission — manifest-declared but not auto-granted; the user has to
  // accept the OS prompt. WebView's per-resource grant in
  // `_configureAndroidWebView` is meaningless without this, so any path
  // that needs the mic goes through `_ensureMicPermission` first.
  static const _permsChannel = MethodChannel('cupitor/perms');
  bool _mediaSessionActive = false;
  // Hosts auto-detected by the native ad-blocker that haven't been confirmed yet.
  final List<String> _detectedAdHosts = [];
  bool _adBlockEnabled = true;

  // YouTube playback mode. Empty/null = native YouTube (with our JSON-prune
  // ad-blocker). Otherwise the hostname of an Invidious/Piped front-end (e.g.
  // "piped.video", "yewtu.be") to redirect youtube.com URLs to. Persisted
  // under SharedPreferences key "youtubeFrontend".
  String? _youtubeFrontend;

  /// Editable from Tools. Holds `{word}` / `{source}` / `{target}` until
  /// [renderAiPrompt] fills them in at share time.
  String _aiPromptTemplate = kDefaultAiPromptTemplate;

  // Filmot: persistent channel blacklist (results from these YouTube channels
  // are hidden on filmot.com pages). Edited per-page from the dialog.
  Set<String> _filmotChannelBlacklist = {};
  // When true, blacklist is suppressed in-session only — not persisted.
  bool _filmotBlacklistDisabled = false;
  // Persisted list of saved videos. Each entry: {url, title, channel, savedAt}.
  List<Map<String, String>> _savedVideos = [];
  // Channels observed on the currently-loaded filmot page (in-memory only).
  // Keyed by dialog id so multiple filmot dialogs don't clobber each other.
  final Map<String, Set<String>> _filmotChannelsSeen = {};
  // Per-dialog2 ScaffoldMessenger keys. Dialog2 routes are near-fullscreen
  // and sit above the root Scaffold, so a SnackBar shown via the root
  // ScaffoldMessenger renders behind them and the user never sees it. Each
  // open dialog2 owns its own ScaffoldMessenger via the key below, so
  // feedback (save-confirm, "already saved", etc.) lands inside the dialog.
  final Map<String, GlobalKey<ScaffoldMessengerState>> _dialog2ScaffoldKeys = {};
  // Persistent videoId → channelName cache. Populated by oEmbed lookups, used
  // to apply the channel blacklist to Filmot search results (whose HTML does
  // not include the channel name).
  Map<String, String> _videoChannelCache = {};
  // In-flight oEmbed lookups (by id) so duplicate batches don't double-fetch.
  final Set<String> _videoChannelInflight = {};

  // Floating minimized-dialog chips. They live on the root Overlay so they
  // appear above any open showDialog route (the default bottom-right column
  // is hidden behind a dialog's barrier and inaccessible while a dialog is
  // showing). Each chip remembers its drag position keyed by dialog id.
  OverlayEntry? _floatingChipsEntry;
  final Map<String, Offset> _chipPositions = {};
  final ValueNotifier<int> _minimizedVersion = ValueNotifier(0);

  // Pretend to be Chrome — the default Android WebView UA contains "; wv)",
  // which Google explicitly checks for and uses to refuse OAuth flows
  // ("disallowed_useragent"). Without this, Sign-in-with-Google on sites like
  // filmot.com fails. Applied to every WebViewController we create.
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36';

  // The main browser on macOS identifies as desktop Safari instead: the
  // Android UA above gets sites' touch-first mobile layouts, and YouTube's
  // mobile player treats every mouse click as play/pause, with no theater
  // mode. Safari's UA carries no WebView marker, so Google sign-in still works.
  static const String _macUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Safari/605.1.15';


  static const List<String> _youtubeFrontendInstances = [
    'piped.video',
    'yewtu.be',
    'invidious.fdn.fr',
    'invidious.privacydev.net',
    'inv.nadeko.net',
  ];

  @override
  void dispose() {
    _appBarTimer?.cancel();
    ProfileService.active.removeListener(_onProfileChanged);
    WidgetsBinding.instance.removeObserver(this);
    SpeechHub.release(_speechHubListener);
    _videoNotePoller.dispose();
    HardwareKeyboard.instance.removeHandler(_onMacFullscreenEscape);
    _notifTimer.stop();
    WakelockPlus.disable();
    _adBlockChannel.setMethodCallHandler(null); // stop receiving callbacks
    _mediaKeysChannel.setMethodCallHandler(null);
    if (_mediaSessionActive) {
      // Best-effort deactivation; ignore failures during teardown.
      _mediaKeysChannel.invokeMethod<void>('setActive', {'active': false});
      _mediaSessionActive = false;
    }
    // Save scroll position of the current page before disposing
    final url = _urlController.text.trim();
    if (url.isNotEmpty) _saveScrollPosition(url);
    _urlController.dispose();
    _urlFocusNode.dispose();
    _findController.dispose();
    _dialogErrorNotifier.dispose();
    _snippetLogVersion.dispose();
    _pageLoading.dispose();
    // Clean up all dialog controllers on app dispose
    dialogController = null;
    _dialog1Loaded = false;
    _dialog2Controllers.clear();
    for (final notifier in _dialog2ErrorNotifiers.values) {
      notifier.dispose();
    }
    _dialog2ErrorNotifiers.clear();
    _dialog2Urls.clear();
    _minimizedDialog2s.clear();
    _everMinimizedDialog2s.clear(); // Clean up tracking state
    _floatingChipsEntry?.remove();
    _floatingChipsEntry = null;
    _minimizedVersion.dispose();
    // The page really is going away here, so drop the session without a
    // reply — unlike the dialog-close path above. Also releases the mic,
    // which this dispose() never did.
    _sttStopTimers();
    _sttSession.teardown();
    // Stops the long-press restart loop: it has a pending 200 ms
    // Future.delayed that checks only this flag, and would otherwise reopen
    // the mic on a disposed State.
    _continuousVoiceActive = false;
    _speech.cancel().catchError((_) {});
    // Actually stop the recorder rather than just forgetting about it — a
    // MediaRecorder outliving the app holds the mic against every other app
    // on the device. Unconditional: the flag tracks our intent, and if a
    // stop already failed it would be lying.
    _stopNativeRecordingIfAny();
    _memSampler?.cancel();
    _isListeningNotifier.dispose();
    _dialog1FullscreenNotifier.dispose();
    _dialog1Tts?.stop();
    _dialog1Tts = null;
    // Close any open ML Kit translators in the snippet-bridge pool.
    for (final t in _translatorPool.values) {
      try { t.close(); } catch (_) {}
    }
    _translatorPool.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
      if (_pendingVoiceResumeDialog) {
        _pendingVoiceResumeDialog = false;
        _flushContinuousTranscript();
      }
      _sweepThenPush(); // resume catch-up + rearm (spec: sweep callers)
    } else if (state == AppLifecycleState.paused) {
      WakelockPlus.disable();
      // Don't leave the mic open behind a backgrounded app — the OEM revokes
      // it anyway, and as an error rather than a clean stop, which for the
      // long-press loop means restarting the recognizer over and over in the
      // background. Stopping the capture properly also surfaces whatever was
      // dictated instead of discarding it.
      _sttCancelForMicHandoff();
      // Quietly — _stopContinuousVoiceCapture surfaces the transcript in a
      // dialog, and a screen lock counts as `paused`, so that would queue a
      // dialog the user finds waiting for them later. Stop the engine, keep
      // the transcript, and show it on resume instead.
      if (_continuousVoiceActive || _isListening) {
        _continuousVoiceActive = false;
        _pendingVoiceResumeDialog = _continuousTranscript.isNotEmpty ||
            _continuousPartial.trim().isNotEmpty;
        _speech.cancel().catchError((_) {});
        SpeechHub.release(_speechHubListener);
        if (mounted && _isListening) setState(() => _isListening = false);
        _isListeningNotifier.value = false;
      }
      // Flush WebView cookies to disk so logins survive a force-kill that
      // happens before the system's next periodic flush.
      _flushCookies();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    onMacWindowExitedFullscreen(() => _setMacPageFullscreen(false));
    HardwareKeyboard.instance.addHandler(_onMacFullscreenEscape);
    // Record why we died last time — a system kill leaves no crash report at
    // all, so this log is the only evidence such a death ever happened. Runs
    // un-awaited, so the lines land once the platform channel answers rather
    // than ahead of the rest of startup.
    _reportLastExit();
    _startMemorySampler();
    // Kick the 10s auto-hide timer so the app bar fades on its own after
    // launch (otherwise it only starts on user-driven triggers like
    // selection/voice, and a fresh window would stay open indefinitely).
    if (_autoHideAppBar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAppBarWithTimer();
      });
    }
    // If the webapp was mid-session when we died, put its dialog back so its
    // own restore can run. After the first frame, because opening a dialog
    // needs a built tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reopenWebappViewIfAny();
    });
    // Listen for auto-detected ad hosts coming from the native layer
    if (Platform.isAndroid) {
      _adBlockChannel.setMethodCallHandler((call) async {
        if (call.method == 'onHostDetected') {
          final host = call.arguments['host'] as String?;
          if (host != null && mounted) _showDetectedAdHostBanner(host);
        }
      });
      _mediaKeysChannel.setMethodCallHandler((call) async {
        if (call.method == 'onKey') {
          final key = (call.arguments as Map?)?['key']?.toString();
          if (key != null) _dispatchMediaKeyToDialog1(key);
        }
      });
    }
    // Warm the remote-snippet cache in parallel with prefs/init so the very
    // first navigation can already inject hooks at onPageStarted (instead of
    // waiting for onPageFinished). Critical for the Netflix manifest case —
    // autoplay fires before onPageFinished otherwise.
    _warmRemoteSnippetCache();
    _warmAndInstallFrameScript();
    _permsChannel.setMethodCallHandler(_handlePermsCall);
    _installRenderGuardSoon();
    // Notification delivery must init on EVERY platform (Windows/web/Linux
    // included), unlike the sentence-tagging DB probe below which is
    // Android||iOS only — see _initNotifDelivery's doc comment.
    _initNotifDelivery();
    // Probe sentence-tagging DB readiness in the background. The toolbar
    // tiles check this flag and hide themselves if the open failed (e.g.
    // on macOS host where sqflite isn't wired up).
    if (isSqlitePlatform) {
      CupitorDb.instance.isReady().then((ok) async {
        if (!mounted) return;
        setState(() => _tagDbReady = ok);
        if (ok) {
          await ProfileService.init();
          await PlaylistService.init();
          if (!mounted) return;
          await _loadProfileScopedPrefs();
          ProfileService.active.addListener(_onProfileChanged);
          // Push playlist changes into dialog1's WebView whenever they
          // happen. If dialog1 isn't up, the runJavaScript call
          // silently no-ops (no controller yet) — the language app
          // will fetch on load via the PlaylistBridge 'get' op.
          PlaylistService.changes.addListener(_pushPlaylistsToDialog);
        }
      });
    }
    // Restore persisted segmentation-scope (NOT profile-scoped: it's a
    // UI preference, not a tagging-data preference).
    SharedPreferences.getInstance().then((p) {
      final scope = p.getString('tagScope:web') ?? 'block';
      if (!mounted) return;
      setState(() {
        _tagSegmentationScope = (scope == 'document') ? 'document' : 'block';
      });
    });
    SharedPreferences.getInstance().then((prefs) {
      final savedUrl = prefs.getString('lastUrl') ?? _urlController.text;
      _urlController.text = savedUrl;
      // Load persisted scroll positions
      final scrollJson = prefs.getString('scrollPositions');
      if (scrollJson != null) {
        try {
          final decoded = jsonDecode(scrollJson) as Map<String, dynamic>;
          _scrollPositions = decoded.map((k, v) => MapEntry(k, (v as num).toDouble()));
        } catch (_) {}
      }
      _bookmarks = prefs.getStringList('bookmarks') ?? [];
      final namesJson = prefs.getString('bookmarkNames');
      if (namesJson != null) {
        try {
          final decoded = jsonDecode(namesJson) as Map<String, dynamic>;
          _bookmarkNames = decoded.map((k, v) => MapEntry(k, v.toString()));
        } catch (_) {}
      }
      _githubToken = prefs.getString('githubToken');
      _pageZoomLevel = prefs.getInt('pageZoom') ?? 0;
      _scrollDiagEnabled = prefs.getBool('scrollDiag') ?? false;
      _savePageStrip = prefs.getBool('savePageStripCupitor') ?? false;
      _videoNoteEnabled = prefs.getBool('videoNoteButton') ?? false;
      _studyFsChipEnabled = prefs.getBool('studyFullscreenButton') ?? true;
      if (_videoNoteEnabled) _videoNotePoller.start();
      final yf = prefs.getString('youtubeFrontend');
      _youtubeFrontend = (yf != null && yf.isNotEmpty) ? yf : null;
      // Blank or missing falls back to the shipped wording — see
      // [renderAiPrompt], which treats an empty template the same way.
      _aiPromptTemplate =
          prefs.getString('aiPromptTemplate') ?? kDefaultAiPromptTemplate;
      _filmotChannelBlacklist = (prefs.getStringList('filmotChannelBlacklist') ?? []).toSet();
      final savedJson = prefs.getString('savedVideos');
      if (savedJson != null) {
        try {
          final decoded = jsonDecode(savedJson) as List<dynamic>;
          _savedVideos = decoded.map((e) {
            final m = (e as Map<String, dynamic>);
            return m.map((k, v) => MapEntry(k, (v ?? '').toString()));
          }).toList();
        } catch (_) {}
      }
      final vcJson = prefs.getString('videoChannelCache');
      if (vcJson != null) {
        try {
          final decoded = jsonDecode(vcJson) as Map<String, dynamic>;
          _videoChannelCache = decoded.map((k, v) => MapEntry(k, v.toString()));
        } catch (_) {}
      }
      // Wiktionary collect-words list. Persisted across sessions; toggle state
      // is intentionally NOT persisted (default off on each launch so a stale
      // "collect mode" doesn't silently swallow real clicks).
      _wiktCollectedWords.value = prefs.getStringList('wiktCollectedWords') ?? <String>[];
      _rebuildMainController = (String initialUrl) {
      // Callbacks below close over THIS local, not the _controller field.
      // The field is reassigned when a dead renderer forces a rebuild, and a
      // callback still in flight from the outgoing controller would otherwise
      // act on the incoming one — injecting the old page's scripts into the
      // new WebView, or navigating it somewhere the user never asked for.
      // A fresh local per call keeps each generation's callbacks on their own
      // instance. Same shape as dialog2Controller.
      late final WebViewController c;
      c = WebViewController()
        ..configureForMac()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(Platform.isMacOS ? _macUserAgent : _userAgent)
        ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) {
          _holdVideosForLookup(c);
          _openDialogWithWebview(msg.message.toString().replaceAll('"', ''));
        })
        ..addJavaScriptChannel('FullscreenChannel', onMessageReceived: (msg) {
          if (identical(c, _controller)) _onWebFullscreenChange(msg);
        })
        // Caption lines the user ticked in snippet.js's subtitle sidebar,
        // on their way to the language webapp as manual playlist item(s).
        // Contract: docs/superpowers/specs/2026-09-06-caption-capture-design.md
        ..addJavaScriptChannel('CaptionCollector', onMessageReceived: (msg) => _handleCaptionCollector(c, msg))
        ..addJavaScriptChannel('PdfIframeDetector', onMessageReceived: (msg) => _handlePdfIframe(msg.message))
        ..addJavaScriptChannel('SpaNavigationDetector', onMessageReceived: (msg) => _onSpaNavigation(msg.message))
        ..addJavaScriptChannel('AdHostDetector', onMessageReceived: (msg) => _onJsAdHostDetected(msg.message))
        ..addJavaScriptChannel('SelectionChannel', onMessageReceived: (_) {
          if (_autoHideAppBar && !_showAppBar) _showAppBarWithTimer();
        })
        // Page-side fallback for app-bar gestures. On macOS the WKWebView is
        // a native NSView that swallows pointer events before Flutter's
        // Listener can see them, so the Flutter-level double-tap / long-press
        // never fires. The injected JS posts here instead.
        ..addJavaScriptChannel('AppBarToggleChannel', onMessageReceived: (_) {
          if (_autoHideAppBar) _toggleAppBar();
        })
        ..addJavaScriptChannel('SnippetLogChannel',
            onMessageReceived: _onSnippetLogMessage)
        ..addJavaScriptChannel('TranslateRequest', onMessageReceived: _handleTranslateRequest)
        // Sentence-tagging bridges. SentenceTagHandler carries 'capture'
        // (initial word-tap) and 'extend' (Prev/Next response) payloads.
        // SentenceFilterHandler is currently used only for an initial
        // 'ready' ping; reserved for future filter-side messages.
        ..addJavaScriptChannel('SentenceTagHandler',
            onMessageReceived: (msg) => _onSentenceTagMessage(msg.message))
        ..addJavaScriptChannel('SentenceFilterHandler',
            onMessageReceived: (msg) => _onSentenceFilterMessage(msg.message))
        ..addJavaScriptChannel('LinkLongPress',
            onMessageReceived: (msg) => _handleLinkLongPress(msg.message))
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) async {
              if (!request.isMainFrame) return NavigationDecision.navigate;
              // Redirect YouTube → Invidious/Piped if the user has chosen a
              // front-end. The rewritten URL re-enters this delegate but no
              // longer matches the YouTube host check, so no infinite loop.
              final rewritten = _rewriteYouTubeUrl(request.url);
              if (rewritten != null) {
                c.loadRequest(Uri.parse(rewritten));
                return NavigationDecision.prevent;
              }
              final url = request.url;
              // .epub link clicked anywhere in the main WebView: download
              // through the EPUB reader's helper (so it lands in the
              // app's cache with a stable name) and push the reader.
              // Intercepts on all platforms — the WebView would otherwise
              // either download or show a "this format can't be displayed"
              // error.
              if (_looksLikeEpubUrl(url)) {
                _downloadAndOpenEpub(url);
                return NavigationDecision.prevent;
              }
              // Always intercept .pdf extension URLs on Android before WebView touches them.
              if (Platform.isAndroid && _looksLikePdfUrl(url)) {
                // Navigation is prevented here, so onPageFinished never fires
                // and the usual recorder never runs — yet the document is
                // about to fill the screen. Without this, history would hold
                // different things on Android and macOS for the same reading.
                HistoryStore.record(url);
                if (mounted) setState(() {
                  _urlController.text = url;
                  _currentPdfUrl = url;
                  _lastStartedUrl = url;
                  _extractedPdfHtml = null;
                  _isTextView = false;
                  _isShowingOurHtml = false;
                  _handledPdfUrls.clear();
                });
                return NavigationDecision.prevent;
              }
              if (Platform.isAndroid) {
                if (_androidPendingUrls.contains(url)) {
                  // Second call for this URL = download listener fired = WebView
                  // cannot render the content. Check if it is a PDF.
                  _androidPendingUrls.remove(url);
                  try {
                    final response = await http
                        .head(Uri.parse(url))
                        .timeout(const Duration(seconds: 5));
                    final ct = response.headers['content-type'] ?? '';
                    if (ct.contains('application/pdf') && mounted) {
                      HistoryStore.record(url);
                      // The navigation started but is prevented here, so it
                      // never reports finishing.
                      if (identical(c, _controller)) _pageLoading.finished();
                      setState(() {
                        _urlController.text = url;
                        _currentPdfUrl = url;
                        _lastStartedUrl = url;
                        _extractedPdfHtml = null;
                        _isTextView = false;
                        _isShowingOurHtml = false;
                        _handledPdfUrls.clear();
                      });
                      return NavigationDecision.prevent;
                    }
                  } catch (_) { /* network error — let it proceed */ }
                } else {
                  // First call — allow, but remember so we catch the second call.
                  _androidPendingUrls.add(url);
                  // Auto-clean after 30 s so the set never grows unbounded.
                  Future.delayed(
                    const Duration(seconds: 30),
                    () => _androidPendingUrls.remove(url),
                  );
                }
              }
              return NavigationDecision.navigate;
            },
            onProgress: (percent) {
              if (identical(c, _controller)) _pageLoading.progress(percent);
            },
            onWebResourceError: (error) {
              if (identical(c, _controller)) {
                _pageLoading.failed(isMainFrame: error.isForMainFrame ?? true);
              }
            },
            onPageStarted: (url) {
              if (identical(c, _controller)) _pageLoading.started();
              // A page torn down mid-fullscreen never reports leaving it.
              if (Platform.isAndroid) _setVideoLandscape(false);
              _hideAndroidFullscreen?.call();
              if (_macPageFullscreen) _setMacPageFullscreen(false);
              if (_isShowingOurHtml) return; // our own HTML page, don't reset state
              // Save scroll position of the page we're leaving
              if (_prevPageUrl != null) _saveScrollPosition(_prevPageUrl!);
              _prevPageUrl = url.split('#').first;
              _lastStartedUrl = url;
              setState(() {
                // Show the clean URL without #page=N fragment
                _urlController.text = url.split('#').first;
                if (_looksLikePdfUrl(url)) {
                  // Strip fragment (#page=N) when comparing so reloading
                  // the same PDF with a page anchor doesn't reset state.
                  final baseUrl = url.split('#').first;
                  final baseCurrentPdf = (_currentPdfUrl ?? '').split('#').first;
                  if (baseCurrentPdf != baseUrl) {
                    _currentPdfUrl = baseUrl;
                    _extractedPdfHtml = null;
                    _isTextView = false;
                  }
                } else {
                  _currentPdfUrl = null;
                  _extractedPdfHtml = null;
                  _isTextView = false;
                  _isShowingOurHtml = false;
                  _handledPdfUrls.clear();
                  _pdfViewerController = null;
                  _pdfFitZoom = 0.0;
                  _pdfZoomLevel = 0;
                }
              });
              // On Android, start PDF detection right here — onPageFinished may never
              // fire if the WebView triggers a download intent for the content.
              if (Platform.isAndroid && _currentPdfUrl == null) {
                _checkForPdf(url);
              }
              // Inject the YT ad-blocker as early as possible so its property
              // setter on window.ytInitialPlayerResponse can fire before
              // YouTube's inline assignment script. The script is hostname-
              // gated and idempotent, so it's safe to call on every navigation.
              _injectYouTubeAdBlocker();
              // Inject the cached remote snippet here too — onPageFinished is
              // too late for hooks that need to be in place before the page's
              // own scripts run (e.g. Netflix XHR/fetch override on the
              // manifest endpoint). The snippet self-guards against duplicate
              // installs, so re-running on every navigation is safe.
              _injectRemoteSnippetEarly();
            },
            onPageFinished: (url) {
              if (identical(c, _controller)) _pageLoading.finished();
              if (_isShowingOurHtml) {
                _injectJs(); // only need word-click JS on our own text page
                c.runJavaScript(_linkLongPressJs);
                // Scroll to preserved page position if switching from PDF view
                if (_pendingScrollToPage != null && _pendingScrollToPage! > 1) {
                  final pg = _pendingScrollToPage!;
                  _pendingScrollToPage = null;
                  c.runJavaScript(
                    'document.getElementById("pg-$pg")?.scrollIntoView({behavior:"instant"});'
                  );
                }
                return;
              }
              _pendingPdfPage = null; // clear after PDF loads
              if (Platform.isAndroid) _attachAndroidAdBlocker();
              _injectJs();
              _injectAdBlocker();
              c.runJavaScript(_linkLongPressJs);
              if (Platform.isAndroid) c.runJavaScript(_fullscreenWatcherJs);
              if (Platform.isMacOS) c.runJavaScript(kInPageFullscreenJs);
              _injectSpaHook();
              _injectPageZoom();
              _injectSelectionWatcher();
              if (Platform.isMacOS) _injectAppBarGestureDetector();
              // Detect PDF by content-type (handles non-.pdf URLs like download links)
              // and defer _injectPdfDetector so it never fires on native PDF pages.
              _detectPdfAndInject(url);
              // Where to come back to if the renderer dies and this WebView
              // has to be rebuilt from scratch.
              _lastLoadedUrl = url;
              _recordHistory(url);
              // Restore scroll position for this URL
              _restoreScrollPosition(url);
              _injectRemoteSnippet();
              _injectScrollDiag(c, 'main');
            },
          ),
        );
      // Published only once fully built, so nothing can observe a half-wired
      // controller through the field.
      _controller = c;
      _enableThirdPartyCookies(c);
      final platform = c.platform;
      if (platform is AndroidWebViewController) {
        platform.setCustomWidgetCallbacks(
          onShowCustomWidget: (view, hide) {
            if (!identical(c, _controller) || !mounted) return hide();
            setState(() {
              _androidFullscreenView = view;
              _hideAndroidFullscreen = hide;
            });
          },
          onHideCustomWidget: () {
            if (!identical(c, _controller) || !mounted) return;
            setState(() {
              _androidFullscreenView = null;
              _hideAndroidFullscreen = null;
            });
          },
        );
      }
      // Navigating is deliberately the last thing, and it waits. The WebView
      // has to be in the view tree before the frame agent can be registered on
      // it, and the agent has to be registered before a document starts or it
      // misses that document entirely. Loading here rather than in the cascade
      // above is what puts those three in the right order.
      _loadWhenFrameScriptReady(c, initialUrl);
      };
      _rebuildMainController!(savedUrl);
      setState(() {
        _isControllerReady = true;
      });
    });
  }

  /// Edit the prompt the share sheet sends to an AI app.
  ///
  /// Reset restores the shipped wording rather than clearing the box, so the
  /// placeholders come back with it — a user who has deleted `{word}` has no
  /// other way to recover the spelling.
  void _showAiPromptDialog() {
    final ctrl = TextEditingController(text: _aiPromptTemplate);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI prompt'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sent to whichever app you pick from the share sheet.\n'
                '{word} is the text being looked up, {source} and {target} are '
                'the languages — the direction follows the page toggle.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 8,
                minLines: 4,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: kDefaultAiPromptTemplate,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            child: const Text('Reset'),
            onPressed: () => ctrl.text = kDefaultAiPromptTemplate,
          ),
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          TextButton(
            child: const Text('Save'),
            onPressed: () async {
              final text = ctrl.text.trim();
              // An emptied box means "give me the default back", which is what
              // renderAiPrompt does with a blank template — store it rather
              // than an empty string so the editor reopens showing it.
              final next = text.isEmpty ? kDefaultAiPromptTemplate : text;
              setState(() => _aiPromptTemplate = next);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('aiPromptTemplate', next);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }

  void _showTokenDialog() {
    final ctrl = TextEditingController(text: _githubToken ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('GitHub Token'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: InputDecoration(
            hintText: 'ghp_...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            child: Text('Clear'),
            onPressed: () async {
              setState(() => _githubToken = null);
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('githubToken');
              Navigator.of(ctx).pop();
            },
          ),
          TextButton(
            child: Text('Save'),
            onPressed: () async {
              final token = ctrl.text.trim();
              setState(() => _githubToken = token.isEmpty ? null : token);
              final prefs = await SharedPreferences.getInstance();
              if (token.isEmpty) {
                await prefs.remove('githubToken');
              } else {
                await prefs.setString('githubToken', token);
              }
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }

  /// Save current scroll position for the given URL.
  Future<void> _saveScrollPosition(String url) async {
    if (url.isEmpty || url == 'about:blank') return;
    final baseUrl = url.split('#').first;
    double pos = 0;
    if (_currentPdfUrl != null && !_isTextView) {
      // PDF view: save page number as scroll position
      pos = (_pdfViewerController?.pageNumber ?? 1).toDouble();
    } else {
      // WebView (HTML or text view): save scrollY
      try {
        final result = await _controller.runJavaScriptReturningResult('window.scrollY');
        pos = double.tryParse(result.toString()) ?? 0;
      } catch (_) {}
    }
    if (pos <= 0) return;
    _scrollPositions[baseUrl] = pos;
    // Evict oldest entries if over limit
    if (_scrollPositions.length > _maxScrollEntries) {
      final keys = _scrollPositions.keys.toList();
      for (int i = 0; i < keys.length - _maxScrollEntries; i++) {
        _scrollPositions.remove(keys[i]);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scrollPositions', jsonEncode(_scrollPositions));
  }

  /// Restore scroll position for the given URL.
  void _restoreScrollPosition(String url) {
    final baseUrl = url.split('#').first;
    final pos = _scrollPositions[baseUrl];
    if (pos == null || pos <= 0) return;
    if (_currentPdfUrl != null) {
      // PDF view: restore page number
      _pdfViewerController?.goToPage(pageNumber: pos.round());
    } else {
      // WebView: restore scrollY with a delay for layout to settle
      _controller.runJavaScript(
        'setTimeout(function(){window.scrollTo(0,$pos);},300);'
      );
    }
  }

  /// For text view: adjusts the CSS --fs variable in the loaded HTML.
  /// For native PDF view: steps through pdfrx zoom stops, but anchors to
  /// fit-to-width so tapping the page never resets the level.
  void _changePdfZoom(int delta) {
    if (_isTextView) {
      final newSize = (_pdfTextFontSize + delta).clamp(10, 32);
      if (newSize == _pdfTextFontSize) return;
      setState(() => _pdfTextFontSize = newSize);
      _controller.runJavaScript(
          "document.documentElement.style.setProperty('--fs','${newSize}px');");
    } else if (_pdfViewerController != null) {
      final newLevel = (_pdfZoomLevel + delta).clamp(-2, 8);
      if (newLevel == _pdfZoomLevel) return;
      _pdfZoomLevel = newLevel;
      _applyPdfZoom();
    }
  }

  void _applyPdfZoom() {
    final ctrl = _pdfViewerController;
    if (ctrl == null || _pdfFitZoom <= 0) return;
    final vs = ctrl.viewSize;
    if (vs == null) return;
    final targetZoom = _pdfFitZoom * (1.0 + _pdfZoomLevel * 0.25).clamp(0.25, 4.0);
    final cur = ctrl.currentZoom;
    final t = ctrl.value.getTranslation();
    ctrl.setZoom(
      Offset((vs.width / 2 - t.x) / cur, (vs.height / 2 - t.y) / cur),
      targetZoom,
      duration: const Duration(milliseconds: 200),
    );
  }

  bool _looksLikePdfUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    return path.toLowerCase().endsWith('.pdf');
  }

  /// Watches the page for non-empty text selections and pings Flutter when one
  /// appears, so we can pop the app bar back into view. Debounced so that the
  /// channel doesn't fire for every cursor tick during a drag-select.
  void _injectSelectionWatcher() {
    _controller.runJavaScript(r'''
      (function(){
        if (window.__cupSelectionWatcher) return;
        window.__cupSelectionWatcher = true;
        var lastNonEmpty = '';
        var timer = null;
        document.addEventListener('selectionchange', function(){
          if (timer) clearTimeout(timer);
          timer = setTimeout(function(){
            try {
              var s = (window.getSelection ? window.getSelection().toString() : '') || '';
              s = s.trim();
              if (s && s !== lastNonEmpty) {
                lastNonEmpty = s;
                try { SelectionChannel.postMessage('1'); } catch(e) {}
              } else if (!s) {
                lastNonEmpty = '';
              }
            } catch(e) {}
          }, 150);
        });
      })();
    ''');
  }

  /// Page-side double-click + long-press detector used to toggle the app bar
  /// on macOS, where the native WKWebView swallows pointer events before
  /// Flutter's Listener can see them. Posts to `AppBarToggleChannel` which
  /// drives the same `_toggleAppBar()` Android uses, so behavior matches.
  void _injectAppBarGestureDetector() {
    _controller.runJavaScript(r'''
      (function(){
        if (window.__cupAppBarGestures) return;
        window.__cupAppBarGestures = true;
        var lpTimer = null;
        var downX = 0, downY = 0;
        var SLOP = 12;
        var LP_MS = 500;
        function cancelLp(){ if (lpTimer){ clearTimeout(lpTimer); lpTimer = null; } }
        document.addEventListener('dblclick', function(){
          try { AppBarToggleChannel.postMessage('dbl'); } catch(e) {}
        }, true);
        document.addEventListener('mousedown', function(e){
          downX = e.clientX; downY = e.clientY;
          cancelLp();
          lpTimer = setTimeout(function(){
            lpTimer = null;
            try { AppBarToggleChannel.postMessage('lp'); } catch(e) {}
          }, LP_MS);
        }, true);
        document.addEventListener('mousemove', function(e){
          if (!lpTimer) return;
          if (Math.abs(e.clientX - downX) > SLOP || Math.abs(e.clientY - downY) > SLOP) cancelLp();
        }, true);
        document.addEventListener('mouseup', cancelLp, true);
        document.addEventListener('mouseleave', cancelLp, true);
        window.addEventListener('blur', cancelLp);
      })();
    ''');
  }

  /// Posted when the page enters or leaves fullscreen. macOS: 'mac-enter' /
  /// 'mac-exit' from [kInPageFullscreenJs]. Android: from
  /// [_fullscreenWatcherJs]; only 'landscape' locks rotation, anything else
  /// hands it back.
  void _onWebFullscreenChange(JavaScriptMessage msg) {
    if (Platform.isMacOS) _setMacPageFullscreen(msg.message == 'mac-enter');
    if (Platform.isAndroid) _setVideoLandscape(msg.message == 'landscape');
  }

  /// Esc while a Flutter widget (a floating chip, say) holds keyboard focus;
  /// with the page focused, the page's own handler in [kInPageFullscreenJs]
  /// sees it and Flutter never does.
  bool _onMacFullscreenEscape(KeyEvent e) {
    if (!_macPageFullscreen || e is! KeyDownEvent) return false;
    if (e.logicalKey != LogicalKeyboardKey.escape) return false;
    _setMacPageFullscreen(false);
    return true;
  }

  void _setMacPageFullscreen(bool on) {
    if (on == _macPageFullscreen || !mounted) return;
    setState(() => _macPageFullscreen = on);
    setMacWindowFullscreen(on);
    // The page-side state must follow when the app leaves (navigation, or the
    // window dropping out of fullscreen); a no-op when the page itself left.
    if (!on) {
      _controller
          .runJavaScript('window.__cupExitFakeFs && window.__cupExitFakeFs()')
          .catchError((_) {});
    }
  }

  void _setVideoLandscape(bool landscape) {
    SystemChrome.setPreferredOrientations(landscape
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const []);
  }

  // Scaling is done with CSS `zoom`, not `transform: scale()` — see
  // lib/page_zoom.dart for why the transform broke scrolling in in-page modals.
  void _injectPageZoom() {
    _controller.runJavaScript(pageZoomJs(_pageZoomLevel));
  }

  /// Push the scroll probe's armed state into one WebView. Installing is
  /// idempotent, so this doubles as the re-inject on page load.
  void _injectScrollDiag(WebViewController? ctrl, String tag) {
    if (ctrl == null) return;
    try {
      ctrl.runJavaScript(
        scrollDiagnosticsJs(enabled: _scrollDiagEnabled, tag: tag),
      ).catchError((_) { /* page not ready — next page-finished re-injects */ });
    } catch (_) { /* controller torn down mid-call */ }
  }

  /// Arm / disarm the probe in every live WebView at once. Called from the
  /// Tools drawer, typically *while* a page is stuck — so it injects into the
  /// already-loaded document rather than waiting for a navigation.
  Future<void> _setScrollDiagnostics(bool on) async {
    setState(() => _scrollDiagEnabled = on);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('scrollDiag', on);
    _injectScrollDiag(_controller, 'main');
    _injectScrollDiag(dialogController, 'dialog1');
    for (final entry in _dialog2Controllers.entries) {
      _injectScrollDiag(entry.value, 'dialog2:${entry.key}');
    }
    // Arming is the moment the user is looking at the stuck page, so capture
    // the static picture right away — the gesture verdict comes on their
    // next drag, but the CSS/layout state is already interesting.
    if (on) _snapshotScrollDiag();
  }

  /// One-shot dump of the current scroll-related layout state in every live
  /// WebView, without needing a gesture.
  void _snapshotScrollDiag() {
    for (final ctrl in <WebViewController?>[
      _controller,
      dialogController,
      ..._dialog2Controllers.values,
    ]) {
      if (ctrl == null) continue;
      try {
        ctrl.runJavaScript(scrollDiagSnapshotJs).catchError((_) {});
      } catch (_) {}
    }
  }

  Future<void> _changePageZoom(int delta) async {
    final next = (_pageZoomLevel + delta).clamp(-4, 10);
    if (next == _pageZoomLevel) return;
    setState(() => _pageZoomLevel = next);
    _injectPageZoom();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pageZoom', _pageZoomLevel);
  }

  /// Does a HEAD request to check if [url] serves PDF content.
  /// Sets [_currentPdfUrl] if confirmed. Safe to call from both
  /// onPageStarted and onPageFinished — the _lastStartedUrl guard
  /// discards results that arrive after the user has navigated away.
  Future<void> _checkForPdf(String url) async {
    if (_currentPdfUrl != null) return;
    try {
      final response = await http.head(Uri.parse(url)).timeout(const Duration(seconds: 5));
      final ct = response.headers['content-type'] ?? '';
      if (ct.contains('application/pdf')) {
        if (!mounted || _lastStartedUrl != url) return;
        setState(() { _currentPdfUrl = url; });
      }
    } catch (_) { /* best-effort; non-critical */ }
  }

  /// After page load, check if the page is a PDF and — if not — inject the
  /// iframe PDF detector. (The detector must NOT run on native PDF pages.)
  Future<void> _detectPdfAndInject(String url) async {
    await _checkForPdf(url);
    if (_currentPdfUrl != null) return; // it's a PDF — don't inject iframe detector
    if (!mounted || _lastStartedUrl != url) return;
    _injectPdfDetector();
  }

  Future<void> _togglePdfTextView() async {
    if (_currentPdfUrl == null) return;
    if (_isTextView) {
      // --- Text → PDF: get visible page number from text view ---
      int visiblePage = 1;
      try {
        final result = await _controller.runJavaScriptReturningResult('''
          (function() {
            var best = 1;
            var els = document.querySelectorAll('.pg[id^="pg-"]');
            for (var i = 0; i < els.length; i++) {
              var r = els[i].getBoundingClientRect();
              if (r.top <= window.innerHeight / 2) {
                best = parseInt(els[i].id.replace('pg-', ''));
              }
            }
            return best;
          })();
        ''');
        visiblePage = int.tryParse(result.toString()) ?? 1;
      } catch (_) {}

      // Switch state — PdfViewer overlay reappears and navigates to page
      setState(() { _isTextView = false; _isShowingOurHtml = false; });
      _pdfViewerController?.goToPage(pageNumber: visiblePage);
      return;
    }

    // --- PDF → Text: get current page from PdfViewer ---
    int currentPage = _pdfViewerController?.pageNumber ?? 1;

    // Build or reuse cached rich HTML
    if (_extractedPdfHtml == null) {
      setState(() => _isExtractingPdf = true);
      try {
        final response = await http.get(Uri.parse(_currentPdfUrl!), headers: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        }).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          debugPrint('PDF fetch failed: HTTP ${response.statusCode}');
          setState(() => _isExtractingPdf = false);
          return;
        }
        final doc = await PdfDocument.openData(response.bodyBytes);
        _extractedPdfHtml = await _buildPdfHtml(doc);
        await doc.dispose();
      } catch (e) {
        debugPrint('PDF extraction error: $e');
        setState(() => _isExtractingPdf = false);
        return;
      }
      setState(() => _isExtractingPdf = false);
    }
    if (_extractedPdfHtml == null || _extractedPdfHtml!.isEmpty) {
      debugPrint('No extractable text in PDF (image-based?).');
      return;
    }
    setState(() { _isTextView = true; _isShowingOurHtml = true; });
    await _controller.loadHtmlString(_extractedPdfHtml!);
    // After page loads, scroll to the page marker
    _pendingScrollToPage = currentPage;
    // onPageFinished will inject utils.js and scroll to the page marker
  }

  // ---------------------------------------------------------------------------
  // Rich PDF HTML builder (research-paper-aware)
  // ---------------------------------------------------------------------------

  Future<String> _buildPdfHtml(PdfDocument doc) async {
    final buf = StringBuffer();
    buf.write('<!DOCTYPE html><html><head>'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>'
        ':root{--fs:${_pdfTextFontSize}px}'
        'body{font-family:Georgia,serif;font-size:var(--fs);line-height:1.75;'
        'padding:20px 28px;margin:0 auto;max-width:720px;background:#fff;'
        '-webkit-user-select:text;user-select:text;}'
        'p{margin:0 0 0.45em;}'
        '.pg{text-align:center;color:#888;font-size:0.78em;'
        'margin:1.4em 0 1em;letter-spacing:0.12em;}'
        '.gap{display:block;border:1px dashed #bbb;border-radius:4px;'
        'padding:8px 12px;margin:10px 0;color:#999;font-style:italic;'
        'font-size:0.82em;text-align:center;background:#f8f8f8;}'
        '.fn{border-top:1px solid #ccc;margin-top:14px;padding-top:8px;'
        'font-size:0.80em;color:#444;line-height:1.5;}'
        '.fn-lbl{color:#999;font-size:0.75em;letter-spacing:0.08em;margin-bottom:4px;}'
        '</style></head><body>');
    bool hasAnyText = false;
    for (int pi = 0; pi < doc.pages.length; pi++) {
      final page = doc.pages[pi];
      final pt = await page.loadText();
      final allFrags = pt.fragments.where((f) => f.text.trim().isNotEmpty).toList();
      buf.write('<div class="pg" id="pg-${pi + 1}">— Page ${pi + 1} —</div>');
      if (allFrags.isEmpty) continue;
      hasAnyText = true;

      // Compute per-fragment average char heights for font-size detection
      final fragHeights = <double>[];
      for (final f in allFrags) {
        final rects = f.charRects.where((r) => r.height > 1).toList();
        fragHeights.add(rects.isEmpty ? 0.0
            : rects.map((r) => r.height).reduce((a, b) => a + b) / rects.length);
      }

      // Median char height ≈ body font size in PDF points
      final nonZeroH = fragHeights.where((h) => h > 0).toList()..sort();
      final medH = nonZeroH.isEmpty ? 10.0 : nonZeroH[nonZeroH.length ~/ 2];

      // Detect footnotes by structure: cluster fragments into lines, then
      // scan from bottom up looking for lines that start with a digit
      // (e.g. "1 Some footnote text..." or "12 Another footnote").
      // The footnote block is the contiguous run of such numbered lines
      // at the bottom of the page (in the lower 40%).

      // First, cluster ALL fragments into lines (same logic as _emitLines)
      final sorted = [...allFrags]..sort((a, b) => b.bounds.top.compareTo(a.bounds.top));
      final pageLines = <List<PdfPageTextFragment>>[];
      {
        var cur = <PdfPageTextFragment>[sorted.first];
        double cySum = sorted.first.bounds.top;
        int cyCount = 1;
        final yt = medH * 0.6;
        for (int i = 1; i < sorted.length; i++) {
          final f = sorted[i];
          if ((cySum / cyCount - f.bounds.top).abs() < yt) {
            cur.add(f);
            cySum += f.bounds.top;
            cyCount++;
          } else {
            pageLines.add(cur);
            cur = [f];
            cySum = f.bounds.top;
            cyCount = 1;
          }
        }
        pageLines.add(cur);
      }
      // Sort fragments within each line left-to-right
      for (final line in pageLines) {
        line.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      }

      // Scan from the last line upward; collect lines that belong to footnotes.
      // A footnote-starting line begins with a digit. Continuation lines
      // (that don't start with a digit) are included if they follow a
      // footnote-starting line without a large gap.
      final pageBottom = page.height * 0.45; // only look in lower 45%
      final fnLineIndices = <int>{};
      bool inFootnoteRegion = false;

      // Pre-compute average char height per line
      final lineAvgHeights = <int, double>{};
      for (int li = 0; li < pageLines.length; li++) {
        double h = 0; int c = 0;
        for (final f in pageLines[li]) {
          for (final r in f.charRects) {
            if (r.height > 1) { h += r.height; c++; }
          }
        }
        lineAvgHeights[li] = c > 0 ? h / c : medH;
      }

      for (int li = pageLines.length - 1; li >= 0; li--) {
        final line = pageLines[li];
        final lineTop = line.map((f) => f.bounds.top).reduce(math.max);
        if (lineTop > pageBottom) break; // past the lower region

        final lineText = line.map((f) => f.text).join(' ').trim();
        if (lineText.isEmpty) continue;

        // Skip lone page numbers (just digits, very short)
        if (RegExp(r'^\d{1,4}$').hasMatch(lineText)) continue;

        final avgLineH = lineAvgHeights[li] ?? medH;
        final isSmallFont = avgLineH < medH * 0.93;

        // "1. Text..." or "12. Text..." — numbered footnote pattern
        final startsWithNum = RegExp(r'^\d+[\.\)]?\s').hasMatch(lineText);
        if (startsWithNum && isSmallFont) {
          // Strong: numbered + smaller font → footnote start
          inFootnoteRegion = true;
          fnLineIndices.add(li);
        } else if (inFootnoteRegion && isSmallFont) {
          // Continuation line (wrapped footnote text, same small font)
          fnLineIndices.add(li);
        } else if (inFootnoteRegion && !isSmallFont) {
          // Hit normal-sized text — footnote region ends
          break;
        }
      }

      // Separate body and footnote fragments
      final body = <PdfPageTextFragment>[];
      final fn = <PdfPageTextFragment>[];
      if (fnLineIndices.isNotEmpty) {
        final fnFrags = <PdfPageTextFragment>{};
        for (final li in fnLineIndices) {
          fnFrags.addAll(pageLines[li]);
        }
        for (final f in allFrags) {
          if (fnFrags.contains(f)) {
            fn.add(f);
          } else {
            body.add(f);
          }
        }
      } else {
        body.addAll(allFrags);
      }

      // Sort top-to-bottom (largest y = top of page in PDF coords)
      body.sort((a, b) => b.bounds.top.compareTo(a.bounds.top));
      fn.sort((a, b) => b.bounds.top.compareTo(a.bounds.top));

      _emitLines(buf, body, medH, isFootnote: false);
      if (fn.isNotEmpty) {
        buf.write('<div class="fn"><div class="fn-lbl">Footnotes</div>');
        _emitLines(buf, fn, medH, isFootnote: true);
        buf.write('</div>');
      }
    }
    if (!hasAnyText) return '';
    buf.write('</body></html>');
    return buf.toString();
  }

  void _emitLines(StringBuffer buf, List<PdfPageTextFragment> frags,
      double medH, {required bool isFootnote}) {
    if (frags.isEmpty) return;

    // --- Step 1: Cluster fragments into lines by y-position ---
    // Use a running average for the cluster's y so drift doesn't accumulate.
    final lines = <List<PdfPageTextFragment>>[];
    var cur = <PdfPageTextFragment>[frags.first];
    double clusterYSum = frags.first.bounds.top;
    int clusterCount = 1;
    final yThresh = medH * 0.6; // tighter threshold: 60% of median char height

    for (int i = 1; i < frags.length; i++) {
      final f = frags[i];
      final clusterAvgY = clusterYSum / clusterCount;
      if ((clusterAvgY - f.bounds.top).abs() < yThresh) {
        cur.add(f);
        clusterYSum += f.bounds.top;
        clusterCount++;
      } else {
        lines.add(cur);
        cur = [f];
        clusterYSum = f.bounds.top;
        clusterCount = 1;
      }
    }
    lines.add(cur);

    // --- Step 2: Compute line positions and typical spacing ---
    // Pre-sort each line and compute top/bottom for gap analysis.
    final lineTops = <double>[];
    final lineBottoms = <double>[];
    for (final line in lines) {
      line.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      lineTops.add(line.map((f) => f.bounds.top).reduce(math.max));
      lineBottoms.add(line.map((f) => f.bounds.bottom).reduce(math.min));
    }

    // Compute typical inter-line gap from the middle 80% of gaps
    // (excludes heading gaps at top and section breaks)
    final interGaps = <double>[];
    for (int i = 1; i < lines.length; i++) {
      final gap = lineBottoms[i - 1] - lineTops[i];
      if (gap > 0) interGaps.add(gap);
    }
    interGaps.sort();
    final medGap = interGaps.isEmpty ? medH * 1.5
        : interGaps[interGaps.length ~/ 2];
    // A gap is "large" if it exceeds both:
    //   - 3× the median inter-line gap (adapts to the page's actual spacing)
    //   - 2.5× the body font height (absolute floor)
    final largeGapThresh = math.max(medGap * 3.0, medH * 2.5);

    // --- Step 3: Render each line with gap-aware joining ---
    for (int li = 0; li < lines.length; li++) {
      final line = lines[li];

      // Detect large vertical gaps → image/figure placeholder
      // Skip last line (page number). Check that both flanking lines have
      // substantial text so lone headers/page numbers don't trigger it.
      if (!isFootnote && li > 0 && li < lines.length - 1
          && lineBottoms[li - 1] - lineTops[li] > largeGapThresh) {
        final prevText = lines[li - 1].map((f) => f.text).join(' ').trim();
        final curText = line.map((f) => f.text).join(' ').trim();
        if (prevText.length > 10 && curText.length > 10) {
          buf.write('<span class="gap">[ Figure / Image / Diagram ]</span>');
        }
      }

      // Compute average char width for space-detection threshold
      double totalW = 0; int charCount = 0;
      for (final f in line) {
        for (final r in f.charRects) {
          if (r.width > 0.5) { totalW += r.width; charCount++; }
        }
      }
      final avgCharW = charCount > 0 ? totalW / charCount : medH * 0.5;

      // Join fragments: use actual horizontal gap to decide spacing
      final sb = StringBuffer();
      for (int i = 0; i < line.length; i++) {
        final frag = line[i];
        if (i > 0) {
          final prevRight = line[i - 1].bounds.right;
          final curLeft = frag.bounds.left;
          final gap = curLeft - prevRight;
          // Gap wider than ~30% of avg char width → insert a space
          if (gap > avgCharW * 0.3) {
            sb.write(' ');
          }
          // Negative or tiny gap → fragments touch, no space needed
        }
        sb.write(_esc(frag.text));
      }
      final text = sb.toString();
      if (text.trim().isNotEmpty) buf.write('<p>$text</p>');
    }
  }

  String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _findInPage(String query, {bool forward = true}) {
    if (query.isEmpty) {
      _clearFindHighlights();
      return;
    }
    final jsStr = jsonEncode(query);
    _controller.runJavaScript('''
      (function() {
        // If query changed, rebuild highlights
        if (window._findQuery !== $jsStr) {
          // Clear old highlights
          document.querySelectorAll('mark._fh').forEach(function(m) {
            var p = m.parentNode;
            p.replaceChild(document.createTextNode(m.textContent), m);
            p.normalize();
          });
          window._findQuery = $jsStr;
          window._findIdx = -1;
          window._findMarks = [];
          // Walk text nodes and wrap matches
          var query = $jsStr.toLowerCase();
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          var node, matches = [];
          while (node = walker.nextNode()) {
            var text = node.textContent.toLowerCase();
            var idx = 0;
            while ((idx = text.indexOf(query, idx)) !== -1) {
              matches.push({node: node, start: idx, length: query.length});
              idx += query.length;
            }
          }
          // Apply marks in reverse so offsets stay valid
          for (var i = matches.length - 1; i >= 0; i--) {
            var m = matches[i];
            var range = document.createRange();
            range.setStart(m.node, m.start);
            range.setEnd(m.node, m.start + m.length);
            var mark = document.createElement('mark');
            mark.className = '_fh';
            mark.style.cssText = 'background:#ffeb3b;padding:0;margin:0;';
            range.surroundContents(mark);
          }
          window._findMarks = Array.from(document.querySelectorAll('mark._fh'));
        }
        if (window._findMarks.length === 0) return;
        // Navigate
        var dir = ${forward ? '1' : '-1'};
        window._findIdx = (window._findIdx + dir + window._findMarks.length) % window._findMarks.length;
        // Reset all to yellow, highlight current in orange
        window._findMarks.forEach(function(m) { m.style.background = '#ffeb3b'; });
        var cur = window._findMarks[window._findIdx];
        cur.style.background = '#ff9800';
        cur.scrollIntoView({block: 'center', behavior: 'smooth'});
      })();
    ''');
  }

  void _clearFindHighlights() {
    _controller.runJavaScript('''
      (function() {
        document.querySelectorAll('mark._fh').forEach(function(m) {
          var p = m.parentNode;
          p.replaceChild(document.createTextNode(m.textContent), m);
          p.normalize();
        });
        window._findQuery = '';
        window._findIdx = -1;
        window._findMarks = [];
      })();
    ''');
  }

  Future<void> _injectSpaHook() {
    const js = r'''
      (function() {
        if (window._spaHooked) return;
        window._spaHooked = true;
        function notify() {
          SpaNavigationDetector.postMessage(window.location.href);
        }
        const _push = history.pushState.bind(history);
        history.pushState = function(...args) { _push(...args); notify(); };
        const _replace = history.replaceState.bind(history);
        history.replaceState = function(...args) { _replace(...args); notify(); };
        window.addEventListener('popstate', notify);
        window.addEventListener('hashchange', notify);
      })();
    ''';
    return _controller.runJavaScript(js);
  }

  void _onSpaNavigation(String url) async {
    setState(() => _urlController.text = url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastUrl', url);
    // A route change inside a single-page site is a page visit to the person
    // using it, even though onPageFinished never fires again.
    _recordHistory(url);
    _injectJs();
    _injectRemoteSnippet();
    _injectAdBlocker();
    _injectYouTubeAdBlocker();
    _injectPdfDetector();
  }

  /// Remembers [url] for the URL bar's suggestions.
  ///
  /// The title is read first and the row written once, rather than writing
  /// twice and patching the title in: a second write arriving after the
  /// same-visit window would count the page as visited twice.
  Future<void> _recordHistory(String url) async {
    if (!isRecordableHistoryUrl(url)) return;
    var title = '';
    try {
      // A wedged renderer never answers. Two seconds, then record without it;
      // the next visit fills the title in.
      title = (await _controller.getTitle().timeout(
            const Duration(seconds: 2),
          )) ??
          '';
    } catch (_) {}
    await HistoryStore.record(url, title: title);
  }

  Future<void> _injectPdfDetector() {
    const js = r'''
      (function() {
        function checkEl(el) {
          const src = el.src || el.data || '';
          if (!src || el.dataset.pdfHandled) return;
          if (/\.pdf(\?.*)?$/i.test(src) || el.type === 'application/pdf') {
            el.dataset.pdfHandled = '1';
            // Resolve relative URLs against the current page
            const abs = new URL(src, window.location.href).href;
            const id = 'pdf_flutter_' + Math.random().toString(36).slice(2);
            el.id = id;
            PdfIframeDetector.postMessage(JSON.stringify({id: id, url: abs}));
          }
        }
        document.querySelectorAll('iframe, embed, object').forEach(checkEl);
        if (!window._pdfObserverAttached) {
          window._pdfObserverAttached = true;
          new MutationObserver(mutations => {
            mutations.forEach(m => m.addedNodes.forEach(node => {
              if (node.nodeType !== 1) return;
              if (['IFRAME','EMBED','OBJECT'].includes(node.tagName)) checkEl(node);
              node.querySelectorAll && node.querySelectorAll('iframe, embed, object').forEach(checkEl);
            }));
          }).observe(document.body, {childList: true, subtree: true});
        }
      })();
    ''';
    return _controller.runJavaScript(js);
  }

  Future<void> _handlePdfIframe(String message) async {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final id = data['id'] as String;
      final url = data['url'] as String;
      final uri = Uri.tryParse(url);
      if (uri == null) return;

      final response = await http.get(uri, headers: {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        debugPrint('PDF fetch failed: HTTP ${response.statusCode} for $url');
        return;
      }

      final doc = await PdfDocument.openData(response.bodyBytes);
      final buffer = StringBuffer('--- Page 1 ---\n\n');
      for (int i = 0; i < doc.pages.length; i++) {
        final pageText = await doc.pages[i].loadText();
        buffer.write(pageText.fullText);
        if (i < doc.pages.length - 1) {
          buffer.write('\n\n--- Page ${i + 2} ---\n\n');
        }
      }
      await doc.dispose();

      // Use jsonEncode so all special characters are properly escaped as a JS string literal
      final textJson = jsonEncode(buffer.toString());
      final js = '''
        (function() {
          const el = document.getElementById('$id');
          if (!el) return;
          const div = document.createElement('div');
          div.style.cssText = 'width:100%;height:100%;overflow:auto;padding:16px;box-sizing:border-box;font-family:serif;font-size:15px;line-height:1.7;white-space:pre-wrap;user-select:text;-webkit-user-select:text;';
          div.textContent = $textJson;
          el.parentNode.replaceChild(div, el);
        })();
      ''';
      _controller.runJavaScript(js);
    } catch (e) {
      debugPrint('PDF handling error: $e');
    }
  }

  Future<void> _injectJs() async {
    // Skip injection entirely on user-excluded URLs so word-lookup +
    // sentence-tagging never wrap or intercept clicks on those pages.
    // The current URL is the most reliable source of truth (URL bar
    // reflects it but may lag through redirects — controller wins).
    final currentUrl = await _controller.currentUrl() ?? _urlController.text;
    if (LookupExclusions.matches(currentUrl)) return;
    final jsCode = await rootBundle.loadString('assets/js/utils.js');
    await _controller.runJavaScript(jsCode);
    // Sentence-tagging companion script — depends on utils.js wrapping
    // words into .clickable-word spans, so injected immediately after.
    try {
      final stagJs = await rootBundle.loadString('assets/js/sentence_tag.js');
      await _controller.runJavaScript(stagJs);
      // Push the segmentation scope BEFORE rehydrate — the rehydrate
      // path mirrors the capture path's scope choice, so swapping the
      // scope on every page load is one of the first JS-side actions.
      await _controller.runJavaScript(
        "window.__cupitorSetSegmentationScope && window.__cupitorSetSegmentationScope('$_tagSegmentationScope');",
      );
      // Push current capture-mode flag in case the JS just reloaded.
      await _controller.runJavaScript(
        'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(${_tagCaptureArmed ? 'true' : 'false'});',
      );
      // Push per-language text-transform rules and apply BEFORE rehydrate
      // so span text and tag identity settle in the same pass. Rules key
      // on document.documentElement.lang — engine picks the right set.
      try {
        final allRules = await TransformRuleStore.loadAll();
        final payload = <String, dynamic>{};
        allRules.forEach((lang, rules) {
          payload[lang] = rules.map((r) => r.toJson()).toList();
        });
        final applyCall = _tagTransformsEnabled
            ? 'window.__cupitorApplyTextTransforms && window.__cupitorApplyTextTransforms();'
            : '';
        await _controller.runJavaScript(
          'window.__cupitorTextTransforms = ${jsonEncode(payload)};'
          'window.__cupitorTransformsEnabled = $_tagTransformsEnabled;'
          '$applyCall',
        );
      } catch (_) { /* transforms are a soft dependency */ }
      await _rehydrateTagsForCurrentPage();
      if (_tagFilterTagIds.isNotEmpty) {
        await _controller.runJavaScript(
          "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(_tagFilterTagIds.toList()))});",
        );
      }
      if (_tagMasksVisible) {
        await _controller.runJavaScript(
          'window.__cupitorSetMasksVisible && window.__cupitorSetMasksVisible(true);',
        );
      }
    } catch (_) { /* sentence_tag is a soft dependency */ }
  }

  Future<void> _loadProfileScopedPrefs() async {
    final id = ProfileService.currentId;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(ProfileService.filterKey('web', id));
    Set<int> parsed = const {};
    if (raw != null && raw.isNotEmpty) {
      parsed = raw.map(int.tryParse).whereType<int>().toSet();
    }
    final masks = prefs.getBool(ProfileService.masksKey('web', id)) ?? false;
    final xformOn = prefs.getBool('tagXformEnabled:web:$id') ?? true;
    if (!mounted) return;
    setState(() {
      _tagFilterTagIds = parsed;
      _tagMasksVisible = masks;
      _tagTransformsEnabled = xformOn;
    });
  }

  Future<void> _onProfileChanged() async {
    // Clear all existing paint/state from the JS side, load the new
    // profile's filter + mask prefs, then re-rehydrate the current
    // page under the new profile.
    await _controller.runJavaScript(
      'window.__cupitorClearAllTags && window.__cupitorClearAllTags();',
    );
    await _loadProfileScopedPrefs();
    await _rehydrateTagsForCurrentPage();
    if (_tagFilterTagIds.isNotEmpty) {
      await _controller.runJavaScript(
        "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(_tagFilterTagIds.toList()))});",
      );
    } else {
      await _controller.runJavaScript(
        "window.__cupitorApplyFilter && window.__cupitorApplyFilter('[]');",
      );
    }
    await _controller.runJavaScript(
      'window.__cupitorSetMasksVisible && window.__cupitorSetMasksVisible($_tagMasksVisible);',
    );
  }

  Future<void> _rehydrateTagsForCurrentPage() async {
    // Always emit an entry-point ping so we can tell from logs whether the
    // method is even being invoked (vs gated out by _tagDbReady) and what
    // profile is active at the time.
    _appendSnippetLog(
      'log',
      '[tagging] rehydrate-entry dbReady=$_tagDbReady profile=${ProfileService.currentId}',
    );
    if (!_tagDbReady) return;
    try {
      final url = await _controller.currentUrl();
      if (url == null) return;
      final locator = canonUrl(url);
      final pid = ProfileService.currentId;
      final rows = await CupitorDb.instance.sentencesForPage(
        profileId: pid,
        surface: 'web',
        locator: locator,
      );
      final totalTags = rows.fold<int>(0, (a, r) => a + r.tags.length);
      // Snapshot a sample row (id + tag list) so we can see whether the
      // join through sentence_tags resolved tags or returned an empty list.
      String sample = '(none)';
      if (rows.isNotEmpty) {
        final r = rows.first;
        sample = 'id=${r.id} tagIds=${r.tags.map((t) => t.id).toList()} '
            'tagNames=${r.tags.map((t) => t.name).toList()}';
      }
      _appendSnippetLog(
        'log',
        '[tagging] rehydrate-query profile=$pid locator=$locator '
            'rows=${rows.length} totalTags=$totalTags first=$sample',
      );
      if (totalTags == 0 && rows.isNotEmpty) {
        final snap = await CupitorDb.instance.diagnosticsSnapshot();
        _appendSnippetLog('log', '[tagging] diag $snap');
      }
      if (rows.isEmpty) {
        // Surface the URL so we can spot locator drift between initial
        // load / back-forward / SPA pushState. Helpful when filter and
        // mask silently no-op because the locator changed shape.
        final msg = '[tagging] no-rows url=$url locator=$locator';
        await _controller.runJavaScript(
          'window.SnippetLogChannel && window.SnippetLogChannel.postMessage(${jsonEncode(msg)});',
        );
        return;
      }
      final json = jsonEncode(rows.map((r) => r.toJson()).toList());
      await _controller.runJavaScript(
        'window.__cupitorApplyTags && window.__cupitorApplyTags(${jsonEncode(json)});',
      );
    } catch (_) {}
  }

  // ---- Sentence-tag JS bridge handlers ----

  void _onSentenceTagMessage(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      switch (m['op']) {
        case 'capture':
          _openCaptureSheet(
            sid: m['sentenceId'] as String,
            text: (m['text'] as String?) ?? '',
            prevFp: (m['prevFp'] as String?) ?? '',
            nextFp: (m['nextFp'] as String?) ?? '',
          );
          break;
        case 'extend':
          _pendingTagExtend?.complete(ExtendResult(
            text: m['text'] as String?,
            prevFp: (m['prevFp'] as String?) ?? '',
            nextFp: (m['nextFp'] as String?) ?? '',
          ));
          _pendingTagExtend = null;
          break;
        case 'editRequest':
          final dbid = (m['dbid'] as num?)?.toInt();
          if (dbid != null) _openEditSheetForDbId(dbid);
          break;
        case 'taggedChoice':
          final raw = m['dbids'];
          final dbids = (raw is List)
              ? raw.map((e) => (e as num).toInt()).toList()
              : <int>[];
          if (dbids.isNotEmpty) _showWebTaggedSentenceChoice(dbids);
          break;
      }
    } catch (e) {
      debugPrint('SentenceTagHandler parse error: $e');
    }
  }

  Future<void> _showWebTaggedSentenceChoice(List<int> dbids) async {
    if (!mounted) return;
    final entries = <({int dbid, TaggedSentenceRow row})>[];
    for (final d in dbids) {
      final r = await CupitorDb.instance.sentenceById(d);
      if (r != null) entries.add((dbid: d, row: r));
    }
    if (!mounted || entries.isEmpty) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'This sentence belongs to ${entries.length} tagged groups.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 8),
            for (final e in entries)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(
                  e.row.sentence.tags.isEmpty
                      ? 'Edit existing (no tags)'
                      : 'Edit "${e.row.sentence.tags.map((t) => t.name).join(', ')}"',
                ),
                subtitle: Text(
                  e.row.sentence.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(ctx).pop(e.dbid),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(ctx).pop(null),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) _openEditSheetForDbId(picked);
  }

  /// Persist any media the user attached / removed in the capture sheet.
  /// [sentenceId] is the just-upserted row id. Called by both the fresh-
  /// capture and edit-existing paths after the sentence itself is saved.
  Future<void> _applyMediaChanges(CaptureSaveResult res, int sentenceId) async {
    for (final id in res.removedMediaIds) {
      final orphanSha = await CupitorDb.instance.deleteMediaReturningOrphanSha1(id);
      if (orphanSha != null) {
        await MediaStore.instance.deleteFile(orphanSha);
      }
    }
    for (final pending in res.pendingMedia) {
      try {
        final info = await MediaStore.instance.ingest(
          pending.file,
          originalFilename: pending.originalFilename,
        );
        final ext = info.extension;
        final kind = MediaStore.kindFromMime(null, ext);
        await CupitorDb.instance.addSentenceMedia(
          sentenceId: sentenceId,
          kind: kind,
          sha1: info.sha1,
          filename: info.originalFilename,
          sizeBytes: info.sizeBytes,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Attach failed: $e')),
          );
        }
      }
    }
    for (final urlAtt in res.pendingUrls) {
      try {
        await CupitorDb.instance.addSentenceMedia(
          sentenceId: sentenceId,
          kind: urlAtt.kind,
          sha1: '', // URL rows carry no file bytes.
          url: urlAtt.url,
          filename: (urlAtt.label != null && urlAtt.label!.isNotEmpty)
              ? urlAtt.label!
              : urlAtt.url,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('URL attach failed: $e')),
          );
        }
      }
    }
  }

  Future<void> _openEditSheetForDbId(int dbid) async {
    if (!_tagDbReady) return;
    final row = await CupitorDb.instance.sentenceById(dbid);
    if (row == null || !mounted) return;
    final s = row.sentence;
    // Edits don't go through capture mode, so no transient JS sid exists;
    // we use 's_db_<id>' to match what rehydrate stamps on the spans.
    final sid = 's_db_$dbid';
    final res = await showTagCaptureSheet(
      context: context,
      initial: CapturePayload(
        sentenceId: sid,
        text: s.text,
        prevFp: s.prevFp ?? '',
        nextFp: s.nextFp ?? '',
      ),
      // Use the ORIGINAL page's surface + locator + profile so the
      // upsert lands on the same row, regardless of the currently
      // active profile or page.
      profileId: row.profileId,
      surface: row.surface,
      locator: row.locator,
      onExtendRequested: (_) async =>
          const ExtendResult(text: null, prevFp: '', nextFp: ''),
      preselectedTagIds: s.tags.map((t) => t.id),
      initialMask: s.mask ?? '',
      extendDisabled: true,
      existingDbId: dbid,
      onSendToPlaylist: (t) => _sendSentenceToWebappPlaylist(
        text: t,
        title: row.pageTitle ?? '',
        // A web locator IS the canonical page address, so it doubles as the
        // card's link back. An EPUB locator is an internal chapter reference
        // and would render as a link that goes nowhere.
        url: row.surface == 'web' ? row.locator : '',
      ),
    );
    if (res == null) return;
    if (res.deleted) {
      try {
        await CupitorDb.instance.deleteSentence(dbid);
        String? currentUrl;
        try { currentUrl = await _controller.currentUrl(); } catch (_) {}
        final inCurrentWebPage = row.surface == 'web' &&
            currentUrl != null &&
            canonUrl(currentUrl) == row.locator;
        if (inCurrentWebPage) {
          // Drop this group's stamp from every covered span and let the
          // helper recompute attrs (preserves overlapping groups).
          await _controller.runJavaScript(
            'window.__cupitorUnstampGroup && window.__cupitorUnstampGroup($dbid);',
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tagged sentence deleted.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
      return;
    }
    try {
      final upsertedId = await CupitorDb.instance.upsertSentenceWithTags(
        profileId: row.profileId,
        surface: row.surface,
        locator: row.locator,
        title: row.pageTitle,
        text: res.text,
        prevFp: res.prevFp.isEmpty ? null : res.prevFp,
        nextFp: res.nextFp.isEmpty ? null : res.nextFp,
        tagIds: res.tagIds,
        mask: res.mask,
      );
      await _applyMediaChanges(res, upsertedId ?? dbid);
      final tags = await CupitorDb.instance.listTags(row.profileId);
      final tagColors = res.tagIds
          .map((id) => tags.firstWhere((t) => t.id == id,
              orElse: () => TagRow(id: 0, profileId: row.profileId, name: '', color: '#FFC107')))
          .where((t) => t.id != 0)
          .map((t) => t.color)
          .toList();
      final tagIdsCsv = res.tagIds.join(',');
      // Repaint via JS only if the edited sentence belongs to a `web`
      // page that's also the page currently in the main WebView; for
      // EPUB edits or web edits on a different URL the JS call is a
      // harmless no-op (no matching spans) — skip it for clarity.
      String? currentUrl;
      try { currentUrl = await _controller.currentUrl(); } catch (_) {}
      final inCurrentWebPage = row.surface == 'web' &&
          currentUrl != null &&
          canonUrl(currentUrl) == row.locator;
      if (inCurrentWebPage) {
        // data-cupitor-dbid is a CSV wherever two captures share a span, so
        // the id has to be matched against the list, not against the whole
        // attribute — otherwise an edit of one of a pair of overlapping
        // tags re-stamps nothing and the commit then unpaints it.
        await _controller.runJavaScript(
          "(function(d,s){document.querySelectorAll('[data-cupitor-dbid].clickable-word')"
          ".forEach(function(el){"
          "var ids=(el.getAttribute('data-cupitor-dbid')||'').split(',');"
          "if(ids.indexOf(d)!==-1)el.setAttribute('data-cupitor-sent',s);});})('$dbid','$sid');",
        );
        await _controller.runJavaScript(
          "window.__cupitorCommitTags && window.__cupitorCommitTags('$sid', $dbid, "
          "${jsonEncode(jsonEncode(tagColors))}, ${jsonEncode(tagIdsCsv)}, ${jsonEncode(res.mask)});",
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved. Visual update will appear next time the page is open.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _setMasksVisible(bool active) async {
    setState(() => _tagMasksVisible = active);
    await _controller.runJavaScript(
      'window.__cupitorSetMasksVisible && window.__cupitorSetMasksVisible($active);',
    );
    final p = await SharedPreferences.getInstance();
    await p.setBool(ProfileService.masksKey('web', ProfileService.currentId), active);
  }

  Future<void> _setTransformsEnabled(bool active) async {
    setState(() => _tagTransformsEnabled = active);
    // On flip: apply or revert immediately. Revert restores each
    // clickable-word's data-cupitor-orig; apply re-runs the substring
    // rewrite pass. No page reload needed.
    final applyCall = active
        ? 'window.__cupitorApplyTextTransforms && window.__cupitorApplyTextTransforms();'
        : 'window.__cupitorRevertTextTransforms && window.__cupitorRevertTextTransforms();';
    await _controller.runJavaScript(
      'window.__cupitorTransformsEnabled = $active;$applyCall',
    );
    final p = await SharedPreferences.getInstance();
    await p.setBool('tagXformEnabled:web:${ProfileService.currentId}', active);
  }

  Future<void> _setSegmentationScope(String scope) async {
    if (scope != 'block' && scope != 'document') return;
    setState(() => _tagSegmentationScope = scope);
    await _controller.runJavaScript(
      "window.__cupitorSetSegmentationScope && window.__cupitorSetSegmentationScope('$scope');",
    );
    final p = await SharedPreferences.getInstance();
    await p.setString('tagScope:web', scope);
  }

  Future<void> _openTagSettingsSheet() async {
    if (!_tagDbReady) return;
    await showTagSettingsSheet(
      context: context,
      initial: TagSettingsValues(
        dbReady: _tagDbReady,
        captureChipVisible: _tagCaptureToggleVisible,
        masksVisible: _tagMasksVisible,
        filterTagIds: _tagFilterTagIds,
        segmentationScope: _tagSegmentationScope,
        showSegmentation: true,
        transformsEnabled: _tagTransformsEnabled,
        // Image-maskover is EPUB-only for now — hide the switch here.
        showMaskImagesOption: false,
      ),
      callbacks: TagSettingsCallbacks(
        onSetCaptureChipVisible: (_) => _toggleCaptureChipVisibility(),
        onSetMasksVisible: (v) => _setMasksVisible(v),
        onSetTransformsEnabled: (v) => _setTransformsEnabled(v),
        onOpenNotificationManager: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const NotificationManagerScreen(),
          ));
          // Manager mutations happened outside the bridge — refresh the
          // webpage's view of lists/schedules when we come back.
          await _pushNotifStateToDialog();
        },
        onOpenFilterSheet: () async {
          final pid = ProfileService.currentId;
          final r = await showTagFilterSheet(
            context: context,
            initial: _tagFilterTagIds,
            profileId: pid,
          );
          if (r == null) return null;
          setState(() => _tagFilterTagIds = r);
          await _controller.runJavaScript(
            "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(r.toList()))});",
          );
          final p = await SharedPreferences.getInstance();
          await p.setStringList(
            ProfileService.filterKey('web', pid),
            r.map((e) => e.toString()).toList(),
          );
          return r;
        },
        onApplyFilter: (s) async {
          setState(() => _tagFilterTagIds = s);
          await _controller.runJavaScript(
            "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(s.toList()))});",
          );
          final p = await SharedPreferences.getInstance();
          await p.setStringList(
            ProfileService.filterKey('web', ProfileService.currentId),
            s.map((e) => e.toString()).toList(),
          );
        },
        onSetSegmentationScope: (s) => _setSegmentationScope(s),
        onOpenBrowser: _openTagBrowser,
      ),
    );
  }

  Future<void> _openTagBrowser() async {
    if (!_tagDbReady) return;
    String? url;
    try { url = await _controller.currentUrl(); } catch (_) {}
    final locator = (url != null && url.isNotEmpty) ? canonUrl(url) : null;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TagBrowserScreen(
          currentSurface: 'web',
          currentLocator: locator,
          onNavigate: (target) {
            // Browser asked us to open a page — load it in the main
            // webview. The route is already popped by the browser.
            _urlController.text = target;
            _loadUrl();
          },
          onEdit: (dbid) => _openEditSheetForDbId(dbid),
        ),
      ),
    );
  }

  void _onSentenceFilterMessage(String _) {
    // Only 'ready' for now — Dart pushes state proactively from _injectJs.
  }

  Future<ExtendResult> _requestExtend(String sid, String direction) {
    _pendingTagExtend?.complete(const ExtendResult(text: null, prevFp: '', nextFp: ''));
    final c = Completer<ExtendResult>();
    _pendingTagExtend = c;
    _controller.runJavaScript(
      "window.__cupitorRequestExtend && window.__cupitorRequestExtend("
      "${jsonEncode(sid)},${jsonEncode(direction)});",
    );
    // Safety net: if JS never replies (page reloaded mid-capture), unblock.
    Future.delayed(const Duration(seconds: 3), () {
      if (!c.isCompleted) {
        c.complete(const ExtendResult(text: null, prevFp: '', nextFp: ''));
        _pendingTagExtend = null;
      }
    });
    return c.future;
  }

  Future<void> _openCaptureSheet({
    required String sid,
    required String text,
    required String prevFp,
    required String nextFp,
  }) async {
    if (!_tagDbReady) return;
    final url = await _controller.currentUrl() ?? '';
    final locator = canonUrl(url);
    final title = await _controller.getTitle();
    final res = await showTagCaptureSheet(
      context: context,
      initial: CapturePayload(
        sentenceId: sid,
        text: text,
        prevFp: prevFp,
        nextFp: nextFp,
      ),
      profileId: ProfileService.currentId,
      surface: 'web',
      locator: locator,
      onExtendRequested: (dir) => _requestExtend(sid, dir),
      onSendToPlaylist: (t) async {
        // Asked at send time rather than when the sheet opened: the player
        // rewrites the address as it plays, so the address that was current a
        // minute ago is not the one this sentence would be filed under.
        final id = await _pageCaptureIdentity();
        return _sendSentenceToWebappPlaylist(
          text: t,
          title: title ?? '',
          url: id.$1.isEmpty ? url : id.$1,
          timeParam: id.$2,
        );
      },
    );
    if (res == null) {
      // Cancelled.
      _controller.runJavaScript(
        "window.__cupitorClearTempHighlight && window.__cupitorClearTempHighlight('$sid');",
      );
      return;
    }
    // Persist + commit visual. We pass the new sentence's DB id and its
    // tag-IDs CSV to commitTags so the JS side stamps both on every
    // span — the filter then sees this sentence without needing a
    // rehydrate text-match round-trip (which is unreliable on some
    // Angular-rendered pages).
    try {
      final profileId = ProfileService.currentId;
      final dbid = await CupitorDb.instance.upsertSentenceWithTags(
        profileId: profileId,
        surface: 'web',
        locator: locator,
        title: title,
        text: res.text,
        prevFp: res.prevFp.isEmpty ? null : res.prevFp,
        nextFp: res.nextFp.isEmpty ? null : res.nextFp,
        tagIds: res.tagIds,
        mask: res.mask,
      );
      if (dbid != null) await _applyMediaChanges(res, dbid);
      final tags = await CupitorDb.instance.listTags(profileId);
      final tagColors = res.tagIds
          .map((id) => tags.firstWhere((t) => t.id == id, orElse: () => TagRow(id: 0, profileId: profileId, name: '', color: '#FFC107')))
          .where((t) => t.id != 0)
          .map((t) => t.color)
          .toList();
      final tagIdsCsv = res.tagIds.join(',');
      _controller.runJavaScript(
        "window.__cupitorCommitTags && window.__cupitorCommitTags(${jsonEncode(sid)}, ${dbid ?? 'null'}, ${jsonEncode(jsonEncode(tagColors))}, ${jsonEncode(tagIdsCsv)}, ${jsonEncode(res.mask)});",
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Future<void> _showTagFilterSheet() async {
    if (!_tagDbReady) return;
    final profileId = ProfileService.currentId;
    final result = await showTagFilterSheet(
      context: context,
      initial: _tagFilterTagIds,
      profileId: profileId,
    );
    if (result == null) return; // cancel
    setState(() => _tagFilterTagIds = result);
    _controller.runJavaScript(
      "window.__cupitorApplyFilter && window.__cupitorApplyFilter(${jsonEncode(jsonEncode(result.toList()))});",
    );
    SharedPreferences.getInstance().then((p) {
      p.setStringList(ProfileService.filterKey('web', profileId),
          result.map((e) => e.toString()).toList());
    });
  }

  void _toggleCaptureChipVisibility() {
    setState(() {
      _tagCaptureToggleVisible = !_tagCaptureToggleVisible;
      if (!_tagCaptureToggleVisible) {
        _tagCaptureArmed = false;
      }
    });
    _controller.runJavaScript(
      'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(${_tagCaptureArmed ? 'true' : 'false'});',
    );
  }

  void _onCaptureChipTap() {
    setState(() => _tagCaptureArmed = !_tagCaptureArmed);
    _controller.runJavaScript(
      'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(${_tagCaptureArmed ? 'true' : 'false'});',
    );
  }

  void _injectRemoteSnippet() {
    http.get(
      Uri.parse('https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/refs/heads/gh-pages/db/js/snippet.js'),
    ).timeout(const Duration(seconds: 5)).then((response) {
      if (response.statusCode == 200) {
        _cachedRemoteSnippet = response.body;
        _controller.runJavaScript(_wrapSnippetWithLogShim(_cachedRemoteSnippet!));
      }
    }).catchError((_) {
      // Network unavailable, timeout, or server error — skip silently
      if (_cachedRemoteSnippet != null) {
        _controller.runJavaScript(_wrapSnippetWithLogShim(_cachedRemoteSnippet!));
      }
    });
  }

  /// Inject the cached snippet at onPageStarted — i.e. before the page's
  /// own scripts run. This is what lets hooks like the Netflix XHR / fetch
  /// override land in time to catch the first manifest request (Netflix
  /// autoplays as soon as the SPA shell is ready, so onPageFinished is too
  /// late for that first call). No network — if the cache is empty (first
  /// run after install), this no-ops and onPageFinished does the full fetch.
  /// The snippet self-guards against double-install via __cup* flags.
  void _injectRemoteSnippetEarly() {
    final cached = _cachedRemoteSnippet;
    if (cached == null) return;
    try { _controller.runJavaScript(_wrapSnippetWithLogShim(cached)); } catch (_) {}
  }

  /// Where the frame agent lives. Remote like `snippet.js`, so a reader that
  /// changes its markup can be handled without an app release.
  static const String _frameBootUrl =
      'https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/refs/heads/gh-pages/db/js/frame-boot.js';

  /// Fetches the frame agent and registers it as a document-start script.
  ///
  /// Unlike `snippet.js`, which the host evaluates per navigation and which
  /// therefore only ever reaches the main frame, this is registered once on
  /// the WebView itself and then runs in EVERY frame of every page — including
  /// cross-origin ones no page script can touch. That is what makes an e-book
  /// reader served from a different subdomain reachable at all.
  /// Where the last good copy of the frame agent is kept between launches.
  static const String _kFrameScriptCachePref = 'frameScriptCache';

  /// Registers the frame agent, stored copy first and network second.
  ///
  /// A document-start script only applies to documents that begin loading
  /// after it is registered. Fetching before registering therefore loses the
  /// agent on any page that starts during the fetch — and restoring the
  /// previous session's page is exactly when the page wins, because it comes
  /// back from cache in milliseconds while the fetch is still in flight.
  /// Registering from preferences turns that wait into a file read.
  Future<void> _warmAndInstallFrameScript() async {
    if (!Platform.isAndroid) return;
    try {
      await _warmAndInstallFrameScriptInner();
    } finally {
      // The first navigation waits on this. Anything that got us here without
      // completing it — a preferences failure, a channel that threw — must
      // still let the page load.
      if (!_frameScriptReady.isCompleted) _frameScriptReady.complete();
    }
  }

  /// The newest copy of the frame agent we hold, cached or fetched.
  ///
  /// Kept so the agent can also be run straight into the main frame. The
  /// document-start registration is the better route where it works, but it is
  /// not the only one, and this is the same source either way — one script to
  /// maintain rather than a second copy in Dart drifting away from it.
  String? _frameScriptSource;

  Future<void> _warmAndInstallFrameScriptInner() async {
    String? cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      cached = prefs.getString(_kFrameScriptCachePref);
    } catch (_) {}
    if (cached != null && cached.trim().isNotEmpty) {
      _frameScriptSource = cached;
      _reportFrameAgent('stored copy -> ${await _registerFrameScript(cached)}');
    }

    final fresh = await _fetchFrameScript();
    if (fresh == null) {
      if (cached == null || cached.trim().isEmpty) {
        _reportFrameAgent('no stored copy, and the fetch failed');
      }
      return;
    }
    if (fresh == cached) return; // registered above, and unchanged
    _frameScriptSource = fresh;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kFrameScriptCachePref, fresh);
    } catch (_) {}
    // Registered now as well as stored. It only takes effect from the next
    // navigation, which is still worth having in this session rather than
    // waiting for the next launch.
    _reportFrameAgent('fetched -> ${await _registerFrameScript(fresh)}');
  }

  /// Reported rather than kept in state: nothing on screen shows it, so a
  /// failed install is only ever diagnosed from the log. Into the snippet log
  /// as well as logcat, because logcat needs a cable — without it, an agent
  /// that never installed and one that installed and found nothing to do are
  /// the same silence on the device.
  void _reportFrameAgent(String msg) {
    debugPrint('[frame-agent] $msg');
    _appendSnippetLog('log', '[frame-agent] $msg');
  }

  /// The agent's source, or null when it could not be fetched.
  Future<String?> _fetchFrameScript() async {
    try {
      final r = await http
          .get(Uri.parse(_frameBootUrl))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200 || r.body.trim().isEmpty) return null;
      return r.body;
    } catch (_) {
      return null;
    }
  }

  /// Completes once the frame agent is registered on at least one WebView.
  ///
  /// The first navigation waits on this. A document-start script only applies
  /// to documents that begin after it is registered, so "register soon" is not
  /// good enough — a page restored from cache starts in milliseconds and would
  /// be missed. Waiting is what turns that from likely into certain.
  final Completer<void> _frameScriptReady = Completer<void>();

  /// Arms the native side with [script] and waits for it to take.
  ///
  /// Arming is one call: the native side remembers the script and registers it
  /// on each WebView as that WebView enters the view tree, which is earlier
  /// than anything reachable from here. This then polls a cheap status call
  /// rather than re-sending the script, which is 40KB a time over the channel.
  Future<String> _registerFrameScript(String script) async {
    String armed;
    try {
      armed = await _permsChannel.invokeMethod<String>(
            'installFrameScript',
            {'script': script},
          ) ??
          'no reply';
    } catch (e) {
      return 'install failed: $e';
    }
    // Nothing to wait for: either it is already on, or this WebView will never
    // support it and waiting would only delay the page for nothing.
    if (!armed.startsWith('armed')) {
      if (!_frameScriptReady.isCompleted) _frameScriptReady.complete();
      return armed;
    }
    var waitMs = 10;
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
      if (waitMs < 200) waitMs *= 2;
      int count;
      try {
        count = await _permsChannel.invokeMethod<int>('frameScriptStatus') ?? 0;
      } catch (_) {
        break;
      }
      if (count > 0) {
        if (!_frameScriptReady.isCompleted) _frameScriptReady.complete();
        return 'registered on $count webview(s) after ${attempt + 1} check(s)';
      }
    }
    // Give up waiting rather than hold the page hostage to a feature that is
    // only ever an improvement on it.
    if (!_frameScriptReady.isCompleted) _frameScriptReady.complete();
    return 'armed, but no webview took it in time';
  }

  /// Issues [c]'s first navigation once the frame agent is registered.
  void _loadWhenFrameScriptReady(WebViewController c, String url) {
    final target = Uri.parse(url);
    if (!Platform.isAndroid) {
      c.loadRequest(target);
      return;
    }
    _awaitFrameScript().then((_) {
      if (!mounted) return;
      try {
        c.loadRequest(target);
      } catch (_) {
        // A malformed saved URL must not leave the app on a blank page with
        // no way back; the bar still holds the text for the user to fix.
      }
    });
  }

  /// Holds the first navigation until the frame agent is in place.
  ///
  /// Bounded, because a page that never loads is a worse failure than a page
  /// that loads without the agent.
  Future<void> _awaitFrameScript() async {
    if (!Platform.isAndroid) return;
    try {
      await _frameScriptReady.future.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Wrap every live WebView's client on the Android side so a dead renderer
  /// stops taking the app down with it, and raise the renderer's priority so
  /// the system reclaims something else first.
  ///
  /// Fire-and-forget, and safe to call as often as you like: views already
  /// guarded are skipped, and a view whose client the plugin has since
  /// replaced is wrapped again. Call it after anything that can add a WebView.
  void _installRenderGuardSoon() {
    if (!Platform.isAndroid) return;
    () async {
      final res = await _installRenderGuard();
      // Logged rather than kept in state, for the same reason as the frame
      // agent: nothing on screen reports it, so a failed install is only ever
      // diagnosed from the log. Stay quiet when there was nothing to do — this
      // runs on every dialog open, and it writes to a capped ring buffer that
      // has to stay readable as an instrument.
      if (!res.startsWith('guarded 0 ')) {
        _appendSnippetLog('log', '[renderer] guard: $res');
      }
    }();
  }

  Future<String> _installRenderGuard() async {
    // Flutter builds the platform view lazily, so early attempts can land
    // before any WebView exists to attach to.
    for (var attempt = 0; attempt < 12; attempt++) {
      try {
        final res =
            await _permsChannel.invokeMethod<String>('installRenderGuard');
        if (res == null || !res.startsWith('no-webview')) return res ?? 'no reply';
      } catch (e) {
        return 'install failed: $e';
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return 'no WebView found after 12 attempts';
  }

  /// The renderer died and the guard kept the app alive. Every WebView in the
  /// app shared that renderer, so they are all dead — there is no "which one"
  /// to report and nothing to reload selectively.
  Future<dynamic> _handlePermsCall(MethodCall call) async {
    if (call.method != 'onRenderProcessGone') return null;
    final args = (call.arguments as Map?) ?? const {};
    final didCrash = args['didCrash'] == true;
    final priority = args['priorityAtExit'];
    // Into the same log the [exit-info] records land in, deliberately: this is
    // the event that used to show up there as CRASH-native, and reading the
    // two side by side is how you tell a guarded death from an unguarded one.
    _appendSnippetLog(
      'warn',
      '[renderer] gone — ${didCrash ? 'renderer crashed' : 'system killed it (memory pressure)'}'
      '  priorityAtExit=$priority',
    );
    if (!mounted) return null;
    _recreateAfterRendererDeath();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(didCrash
            ? 'Web content crashed — the page has been reloaded.'
            : 'Android reclaimed the web content to free memory — the page has been reloaded.'),
        duration: const Duration(seconds: 6),
      ),
    );
    return null;
  }

  /// Rebuild every WebView the dead renderer took with it.
  ///
  /// A WebView whose renderer died is permanently unusable — `reload()` on it
  /// does nothing, because the object itself is what the platform invalidated.
  /// Only a NEW WebView gets a new renderer, which is why this replaces the
  /// controllers rather than reloading them.
  ///
  /// Flipping [_isControllerReady] is what makes the replacement take effect:
  /// it drops the whole subtree, so the old WebViewWidget is disposed and the
  /// next build creates a fresh one around the new controller. Without it the
  /// widget keeps rendering the dead WebView no matter what the field says.
  void _recreateAfterRendererDeath() {
    final rebuild = _rebuildMainController;
    if (rebuild == null) return; // died before the first build; nothing to redo
    // The dead controller cannot be asked for its URL, and the address bar may
    // hold something the user is midway through typing — which loadRequest
    // rejects outright for having no scheme, throwing from the LAST line of
    // the cascade and leaving a fully built but never-navigated WebView.
    // Prefer the last URL that actually loaded.
    final target = _firstLoadableUrl([_lastLoadedUrl, _urlController.text.trim()])
        ?? 'https://google.com';
    // Nor does it finish the load it was in the middle of.
    _pageLoading.finished();
    setState(() {
      _isControllerReady = false;
      // A dead WebView never reports leaving fullscreen.
      _androidFullscreenView = null;
      _hideAndroidFullscreen = null;
    });
    if (Platform.isAndroid) _setVideoLandscape(false);
    try {
      rebuild(target);
    } catch (e) {
      _appendSnippetLog('warn', '[renderer] rebuild failed: $e');
    }
    setState(() => _isControllerReady = true);
    // dialog1 reads its controller from a FIELD, and its WebViewWidget is
    // re-evaluated every time _dialogErrorNotifier fires — so it can be
    // rebuilt in place. Replace the controller first, then pulse the notifier
    // so the builder runs again and wraps the NEW one.
    if (dialogController != null) {
      dialogController = null;
      // The rebuild below takes the "no controller yet" branch, which resets
      // the loaded flag for us.
      _openDialogWithWebview(''); // builds a fresh controller synchronously
      _dialogErrorNotifier.value = 'Reloading — the web content was reclaimed.';
      _dialogErrorNotifier.value = null;
    }
    // dialog2 panels capture their controller as a local when the panel is
    // built, so a replacement cannot reach one that is already open, and
    // clearing the map would only strand its minimised chip. Telling each
    // panel is the honest option: the message reaches an open panel and
    // survives into a restored one, and Close still works.
    for (final n in _dialog2ErrorNotifiers.values) {
      n.value = 'The web content was reclaimed to free memory. '
          'Close this panel and reopen it.';
    }
    // New WebViews mean new clients: without this the replacements are
    // unguarded and the next renderer death is fatal again.
    _installRenderGuardSoon();
  }

  /// First candidate `WebViewController.loadRequest` will actually accept.
  ///
  /// It throws on a URI with no scheme, which is exactly what a half-typed
  /// address bar contains — and because it is the last call in the build
  /// cascade, that throw leaves a fully constructed WebView that never
  /// navigated anywhere. Screening here keeps the failure out of the cascade.
  String? _firstLoadableUrl(List<String?> candidates) {
    for (final c in candidates) {
      if (c == null || c.isEmpty) continue;
      final u = Uri.tryParse(c);
      if (u != null && u.hasScheme && u.hasAuthority) return c;
    }
    return null;
  }

  /// Fire-and-forget cache warm so the first navigation after launch can
  /// still inject early. Runs in parallel with everything else in initState.
  void _warmRemoteSnippetCache() {
    if (_cachedRemoteSnippet != null) return;
    http.get(
      Uri.parse('https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/refs/heads/gh-pages/db/js/snippet.js'),
    ).timeout(const Duration(seconds: 8)).then((response) {
      if (response.statusCode == 200) _cachedRemoteSnippet = response.body;
    }).catchError((_) { /* offline / down — handled by the runtime fetch */ });
  }

  // Wraps the remote snippet in an outer IIFE that shadows `console` with a
  // forwarder to SnippetLogChannel. Closure scope means only code inside this
  // wrapper sees the shim — page scripts continue to use the global console.
  String _wrapSnippetWithLogShim(String snippet) => '''
(function() {
  function _ser(args) {
    return Array.from(args).map(function(a) {
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(' ');
  }
  function _s(level) {
    return function() {
      try { SnippetLogChannel.postMessage(level + '|' + _ser(arguments)); } catch (e) {}
    };
  }
  var console = { log: _s('log'), info: _s('info'), warn: _s('warn'), error: _s('error'), debug: _s('debug') };
  $snippet
})();
''';

  /// `SnippetLogChannel` payloads are `level|message`. Shared by every
  /// WebView that registers the channel so their output interleaves in one
  /// log — the scroll probe relies on this to report from dialog1.
  void _onSnippetLogMessage(JavaScriptMessage msg) {
    final raw = msg.message;
    final pipe = raw.indexOf('|');
    if (pipe < 0) {
      _appendSnippetLog('log', raw);
    } else {
      _appendSnippetLog(raw.substring(0, pipe), raw.substring(pipe + 1));
    }
  }

  void _appendSnippetLog(String level, String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _snippetLogs.add('[$ts] [$level] $msg');
    if (_snippetLogs.length > _kSnippetLogCap) {
      _snippetLogs.removeRange(0, _snippetLogs.length - _kSnippetLogCap);
    }
    _snippetLogVersion.value++;
  }

  /// Report why the app process died last time, into Snippet logs.
  ///
  /// Not every death is a crash, and only crashes reach Play Console. When the
  /// system kills us — because the shared WebView renderer ran out of memory,
  /// say — there is no exception and no tombstone, so crash vitals stay empty
  /// however many times it happens. `ActivityManager` records the real reason;
  /// this is the only way to read it. See `lastExitInfo` in MainActivity.kt.
  ///
  /// Runs once at startup. Android 11+ only — below that the OS keeps no
  /// history and the list comes back empty.
  Future<void> _reportLastExit() async {
    if (!Platform.isAndroid) return;
    // Native-crash tombstones only became readable by the app itself in
    // Android 12, so the OS version decides whether [exit-trace] can ever
    // produce anything. Record it rather than wonder later.
    _appendSnippetLog('log', '[exit-info] os=${Platform.operatingSystemVersion}');
    List<Object?> raw;
    try {
      raw = await _permsChannel.invokeMethod<List<Object?>>('lastExitInfo') ?? [];
    } catch (e) {
      if (!mounted) return;
      _appendSnippetLog('warn', '[exit-info] unavailable: $e');
      return;
    }
    // The reply crosses an await, so the shell can be gone by now — a hot
    // restart, or teardown during a slow startup. `_appendSnippetLog` ticks a
    // ValueNotifier that dispose() has already closed by then.
    if (!mounted) return;
    if (raw.isEmpty) {
      _appendSnippetLog('log', '[exit-info] no process-death history '
          '(needs Android 11+, or this is the first run since install)');
      return;
    }
    // Newest first, per getHistoricalProcessExitReasons.
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['reasonName'] ?? entry['reason'];
      final pssKb = (entry['pss'] as num?)?.toInt() ?? 0;
      final rssKb = (entry['rss'] as num?)?.toInt() ?? 0;
      final ms = (entry['timestamp'] as num?)?.toInt() ?? 0;
      final when = ms > 0
          ? DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String().substring(0, 19)
          : 'unknown time';
      final desc = (entry['description'] as String?) ?? '';
      // Which process died matters as much as why: every WebView in the app
      // shares one renderer, and it runs as <package>:sandboxed_process*. A
      // native crash there is a completely different bug from one in the app
      // process, and the two are indistinguishable without this.
      final proc = (entry['processName'] as String?) ?? '';
      final shortProc = proc.contains(':') ? proc.substring(proc.indexOf(':')) : '';
      _appendSnippetLog('log',
          '[exit-info] $when  $name'
          '${shortProc.isEmpty ? '' : '  proc=$shortProc'}'
          '${pssKb > 0 ? '  pss=${(pssKb / 1024).round()}MB' : ''}'
          '${rssKb > 0 ? '  rss=${(rssKb / 1024).round()}MB' : ''}'
          '${desc.isEmpty ? '' : '  — $desc'}');
      // Only ANRs and native crashes ever carry a trace; saying so for the
      // others keeps the log honest instead of looking like a failure.
      final wantsTrace = name == 'CRASH-native' || name == 'ANR';
      if (wantsTrace) _logExitTrace(entry['trace'], '$name');
    }
  }

  Timer? _memSampler;

  /// Log the memory breakdown by category, every minute.
  ///
  /// A crash at ~1 GB says how much, never what. This shows which bucket is
  /// growing, which is what names the owner — and because it samples while you
  /// use the app, the growth lines up with whatever you were doing. Sampling
  /// costs a `Debug.getMemoryInfo` call, tens of milliseconds, so once a
  /// minute is deliberate; do not make it frequent.
  void _startMemorySampler() {
    if (!Platform.isAndroid) return;
    _sampleMemory();
    _memSampler?.cancel();
    _memSampler = Timer.periodic(const Duration(minutes: 1), (_) => _sampleMemory());
  }

  Future<void> _sampleMemory() async {
    List<Object?>? procs;
    try {
      procs = await _permsChannel.invokeMethod<List<Object?>>('memoryBreakdown');
    } catch (_) {
      return;
    }
    if (procs == null || !mounted) return;
    for (final p in procs) {
      if (p is! Map) continue;
      int mb(String k) => (((p[k] as num?)?.toInt() ?? 0) / 1024).round();
      // Only the suffix distinguishes the processes, and the package prefix is
      // the same on every line — so drop it and keep the log readable.
      final full = (p['name'] as String?) ?? '';
      final label = full.contains(':') ? full.substring(full.indexOf(':')) : 'app';
      // rss first, because that is the unit the exit-info records use and so
      // the only one a live sample can be compared against.
      _appendSnippetLog('log',
          '[mem] $label rss=${mb('rss')}MB'
          '  pss=${mb('totalPss')}MB'
          '  native=${mb('nativeHeap')}MB'
          '  graphics=${mb('graphics')}MB'
          '  java=${mb('javaHeap')}MB'
          '  code=${mb('code')}MB'
          '  other=${mb('privateOther')}MB');
    }
  }

  /// Surface what crashed, from the trace the system kept.
  ///
  /// Two formats arrive here and only one is text: an ANR trace is plain, but
  /// a native-crash tombstone is a protobuf. Rather than parse the proto, pull
  /// the printable runs out of the bytes — the signal name, any abort message
  /// and the `.so` paths on the stack are all stored as plain strings inside
  /// it, and those are what identify the culprit.
  ///
  /// Always logs something. An instrument that goes quiet when it fails is
  /// indistinguishable from one reporting good news, which cost us two
  /// crashes' worth of evidence.
  void _logExitTrace(Object? raw, String reason) {
    if (raw == null) {
      _appendSnippetLog('log', '[exit-trace] $reason: no trace kept by the system');
      return;
    }
    if (raw is! List<int> || raw.isEmpty) {
      _appendSnippetLog('warn',
          '[exit-trace] $reason: unexpected trace type ${raw.runtimeType}');
      return;
    }
    // Replace every non-printable byte with a newline, so printable runs fall
    // out as lines. Works the same for text and for protobuf.
    final split = raw.map((b) => (b >= 0x20 && b < 0x7f) ? b : 0x0a).toList();
    final runs = String.fromCharCodes(split)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.length >= 6)
        .toList();
    _appendSnippetLog('warn',
        '[exit-trace] $reason: ${raw.length} bytes, ${runs.length} strings');
    // Signals, abort messages and shared objects — the identifying parts.
    final seen = <String>{};
    var shown = 0;
    for (final s in runs) {
      final interesting = s.contains('.so') ||
          s.startsWith('SIG') ||
          s.contains('signal') ||
          s.contains('Abort') ||
          s.contains('abort_message');
      if (!interesting || !seen.add(s) || shown >= 25) continue;
      shown++;
      _appendSnippetLog('warn', '[exit-trace] $s');
    }
    if (shown == 0) {
      // Nothing matched: dump the longest few runs so the trace is never a
      // total loss, and so the filter above can be corrected from real data.
      runs.sort((a, b) => b.length.compareTo(a.length));
      for (final s in runs.take(8)) {
        _appendSnippetLog('warn', '[exit-trace] ? $s');
      }
    }
  }

  void _showSnippetLogs() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: const Text('Snippet logs'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear',
              onPressed: () {
                _snippetLogs.clear();
                _snippetLogVersion.value++;
              },
            ),
          ],
        ),
        body: SafeArea(
          child: ValueListenableBuilder<int>(
            valueListenable: _snippetLogVersion,
            builder: (_, __, ___) => _snippetLogs.isEmpty
                ? const Center(child: Text('No logs yet'))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _snippetLogs.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    ));
  }

  /// Attaches the native Android ad-blocking WebViewClient via a platform
  /// channel. Safe to call on every page load — the Kotlin side is idempotent.
  /// Called when JS detects a 3rd-party host contacted during a confirmed ad.
  void _onJsAdHostDetected(String host) {
    if (!mounted) return;
    _showDetectedAdHostBanner(host);
  }

  void _attachAndroidAdBlocker() {
    _adBlockChannel.invokeMethod<void>('attach').catchError((_) {});
  }

  /// Enable third-party cookies on the underlying Android WebView. Many sign-in
  /// flows (OAuth callbacks, Google / GitHub login redirects) set a cookie on
  /// one host and read it back from another — those break unless third-party
  /// cookies are explicitly enabled. Cookies themselves persist across dialog
  /// open/close cycles by default because Android's CookieManager is shared
  /// across all WebViews in the app.
  void _enableThirdPartyCookies(WebViewController controller) {
    if (!Platform.isAndroid) return;
    try {
      final cookieMgr = WebViewCookieManager().platform;
      final platform = controller.platform;
      if (cookieMgr is AndroidWebViewCookieManager
          && platform is AndroidWebViewController) {
        cookieMgr.setAcceptThirdPartyCookies(platform, true);
      }
    } catch (_) { /* best-effort — fall back to default cookie policy */ }
    _configureAndroidWebView(controller);
  }

  /// Extra Android-only WebView configuration required by sites like Spotify
  /// that need (a) autoplay without a synthetic user gesture, and (b) Widevine
  /// DRM (which Android exposes via the `PROTECTED_MEDIA_ID` permission). Also
  /// blanket-grants common media permissions (mic / camera / midi) when a page
  /// requests them, since the user already had to trust the URL to load it.
  void _configureAndroidWebView(WebViewController controller) {
    if (!Platform.isAndroid) return;
    try {
      final platform = controller.platform;
      if (platform is! AndroidWebViewController) return;
      // Spotify, YouTube embeds, and most modern streaming sites refuse to
      // start audio if the WebView's `mediaPlaybackRequiresUserGesture` is
      // left at its default `true` — they treat the missing gesture as an
      // autoplay-blocked signal and don't even attempt playback.
      platform.setMediaPlaybackRequiresUserGesture(false);
      // Honour the page's <meta name="viewport">. webview_flutter_android
      // constructs every controller with useWideViewPort=false +
      // loadWithOverviewMode=true, which means the WebView IGNORES the meta
      // tag (including `width=device-width, initial-scale=1`) and instead
      // zooms the whole page out to fit whatever the content's widest box is.
      //
      // That zoom-out is not cosmetic: it desynchronises the layout viewport
      // from the visual one. `window.innerWidth/innerHeight` then report the
      // zoomed-out size while fixed-position elements are still laid out
      // against the smaller layout viewport, so a page that sizes a floating
      // panel from innerWidth/innerHeight grows it past the layout viewport.
      // Touch scrolling inside such a panel then latches onto the root
      // scroller instead — and if the page has locked body scroll (the usual
      // modal idiom) nothing moves at all. Mobile browsers honour the meta
      // and stay at scale 1, which is why the same page scrolls fine there.
      //
      // Every page we generate ourselves already declares
      // `width=device-width, initial-scale=1`, so this only starts obeying
      // markup that was always meant to apply. Overview mode stays on: with
      // the meta honoured it only kicks in for pages that genuinely ask for
      // a viewport wider than the screen, which is the browser behaviour.
      platform.setUseWideViewPort(true);
      // Grant requested resource permissions. `protectedMediaId` is needed
      // for Widevine DRM (Spotify Web Player); `microphone` is needed for
      // the manual-entry audio recorder. For mic and camera we ALSO have
      // to make sure Android's runtime `RECORD_AUDIO` / `CAMERA` is granted
      // to the host app — granting the WebView resource without the OS-level
      // permission still results in `getUserMedia` rejecting silently.
      platform.setOnPlatformPermissionRequest((request) {
        final needsMic = request.types.contains(WebViewPermissionResourceType.microphone);
        final needsCamera = request.types.contains(WebViewPermissionResourceType.camera);
        if (needsMic || needsCamera) {
          // Fire-and-forget — grant() / deny() are themselves async.
          () async {
            // One at a time: Android shows a single permission prompt at once.
            final ok = (!needsMic || await _ensureMicPermission())
                && (!needsCamera || await _ensureCameraPermission());
            try {
              if (ok) await request.grant();
              else    await request.deny();
            } catch (_) {}
          }();
        } else {
          try { request.grant(); } catch (_) {}
        }
      });
    } catch (_) { /* best-effort */ }
  }

  /// Ensure Android's `RECORD_AUDIO` runtime permission is granted to the
  /// host app, prompting the user if needed. Returns true on grant, false
  /// on denial / any error. iOS/macOS are no-ops (mic permission there is
  /// handled at the OS level when WKWebView calls into AVCaptureSession,
  /// and prompted via the app's Info.plist usage descriptions).
  Future<bool> _ensureMicPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _permsChannel.invokeMethod<bool>('requestMicrophone');
      return ok ?? false;
    } catch (e) {
      debugPrint('mic permission request failed: $e');
      return false;
    }
  }

  /// Android `CAMERA` counterpart of [_ensureMicPermission].
  Future<bool> _ensureCameraPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _permsChannel.invokeMethod<bool>('requestCamera');
      return ok ?? false;
    } catch (e) {
      debugPrint('camera permission request failed: $e');
      return false;
    }
  }

  /// Reads the language webapp's own search box (`#searchText`) and its
  /// direction toggle (`#toggleLangCb`) out of dialog1's WebView.
  ///
  /// Returns null when the page can't be reached at all — no dialog1 yet, or
  /// the renderer is wedged and the call times out. A page that simply lacks
  /// those controls (dialog1 navigated elsewhere) reports empty text and the
  /// default direction instead. Either way callers see no usable text and
  /// fall back to their own sources.
  Future<({String text, bool toEnglish})?> _readWebappSearchState() async {
    final controller = dialogController;
    if (controller == null) return null;
    const js = '''
      (function() {
        try {
          var el = document.getElementById('searchText');
          var cb = document.getElementById('toggleLangCb');
          return JSON.stringify({
            text: el ? String(el.value || '') : '',
            toEnglish: !(cb && cb.checked)
          });
        } catch (e) {
          return JSON.stringify({ text: '', toEnglish: true });
        }
      })();
    ''';
    try {
      final raw = await controller
          .runJavaScriptReturningResult(js)
          .timeout(const Duration(seconds: 2));
      var s = raw.toString();
      if (s.startsWith('"') && s.endsWith('"')) s = jsonDecode(s) as String;
      final d = jsonDecode(s) as Map<String, dynamic>;
      return (
        text: (d['text'] as String? ?? '').trim(),
        toEnglish: d['toEnglish'] != false,
      );
    } catch (_) {
      return null;
    }
  }

  /// Builds an "explain this word to me" prompt and hands it off to any
  /// installed app via Android's share-text chooser. Users typically pick
  /// an AI assistant (ChatGPT / Claude / Gemini / Perplexity / etc.) but
  /// the chooser surface accepts every text consumer the OS knows about.
  Future<void> _shareSearchTextToAi() async {
    // The webapp's search box is the source of truth: it holds exactly what
    // the user is looking at, including anything they typed or edited
    // straight into the page after the lookup was dispatched.
    final state = await _readWebappSearchState();
    var word = state?.text ?? '';
    // The page's toggle describes THE SEARCH BOX's contents and nothing else,
    // so it may only be trusted when the word actually came from there. A
    // word taken from a fallback source keeps the app's usual direction
    // (study language → English) no matter how the toggle happens to sit.
    var toEnglish = true;
    if (word.isNotEmpty) {
      toEnglish = state!.toEnglish;
    } else {
      // Page unreadable or the box is empty — fall back to whatever the user
      // copied onto the system clipboard (e.g. text selected in the reader),
      // then to the currently looked-up word.
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      word = clip.isNotEmpty ? clip : _currentDialogText.trim();
    }
    if (word.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to share — copy or look up a word first.'), duration: Duration(seconds: 2)),
      );
      return;
    }
    // _languageParams maps language codes ('sv') to friendly names
    // ('swedish'); title-case them since they're going into a sentence.
    final study = _titleCase(_languageParams[_selectedLanguage] ?? _selectedLanguage);
    // English is the other side of every pair in this app (cf. "Translation
    // ($_selectedLanguage → en)" in the YouTube subtitle dialog). The page's
    // toggle says which side the search term is IN — checked means the user
    // is searching in English — so the prompt's direction follows it.
    const english = 'English';
    final src = toEnglish ? study : english;
    final tgt = toEnglish ? english : study;
    final prompt = renderAiPrompt(
      _aiPromptTemplate,
      word: word,
      source: src,
      target: tgt,
    );
    if (!Platform.isAndroid) {
      // iOS/macOS share-sheet would need a different channel — for now,
      // just put the prompt on the clipboard and tell the user.
      await Clipboard.setData(ClipboardData(text: prompt));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prompt copied to clipboard'), duration: Duration(seconds: 2)),
      );
      return;
    }
    try {
      await _permsChannel.invokeMethod<void>('shareText', {
        'text': prompt,
        'chooserTitle': 'Ask AI about "$word"',
        'subject': 'Translate "$word"',
      });
    } catch (e) {
      debugPrint('share intent failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open share sheet: $e'), duration: const Duration(seconds: 2)),
      );
    }
  }

  String _titleCase(String s) =>
      s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1).toLowerCase());

  /// Release the mic from `speech_to_text` so a subsequent
  /// `getUserMedia({audio:true})` inside dialog1's WebView can open it.
  /// AudioRecord can only be held by one consumer at a time on Android,
  /// and if continuous voice capture is still active (or even just settling
  /// after a one-shot listen), getUserMedia rejects with NotReadableError.
  ///
  /// Always issue stop+cancel — we've seen cases where `_continuousVoiceActive`
  /// is false but `_speech` still holds the SpeechRecognizer (e.g. a partial
  /// onError that never updated our flag). stop+cancel are no-ops when STT
  /// isn't running, so the unconditional call is safe.
  Future<void> _releaseMicFromSpeechToText() async {
    _continuousVoiceActive = false;
    try { await _speech.stop(); } catch (_) {}
    try { await _speech.cancel(); } catch (_) {}
    if (mounted && _isListening) setState(() => _isListening = false);
    _isListeningNotifier.value = false;
    // The underlying AudioRecord teardown is async at the OS layer — give
    // it a beat to actually let go before the WebView tries to claim it.
    // 500 ms covers SpeechRecognizer's own settle time on slower devices;
    // below that getUserMedia can still race with NotReadableError.
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Tell Android's CookieManager to flush its in-memory cookie jar to disk.
  /// WebView flushes periodically on its own, but a force-kill before the
  /// next periodic flush loses recently-set cookies (logins). Called on app
  /// pause so persistence is guaranteed.
  Future<void> _flushCookies() async {
    if (!Platform.isAndroid) return;
    try {
      await _adBlockChannel.invokeMethod<void>('flushCookies');
    } catch (_) {}
  }

  /// If [_youtubeFrontend] is set and [url] points to YouTube, return the URL
  /// rewritten to the chosen Invidious/Piped instance. Returns null otherwise.
  String? _rewriteYouTubeUrl(String url) {
    final frontend = _youtubeFrontend;
    if (frontend == null || frontend.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      // Short-link: /VIDEO_ID → /watch?v=VIDEO_ID, preserve any other params.
      if (uri.pathSegments.isEmpty) return null;
      final id = uri.pathSegments.first;
      final params = Map<String, String>.from(uri.queryParameters);
      params['v'] = id;
      return Uri(
        scheme: 'https', host: frontend, path: '/watch', queryParameters: params,
      ).toString();
    }
    final isYouTube = host == 'youtube.com'
        || host == 'www.youtube.com'
        || host == 'm.youtube.com';
    if (!isYouTube) return null;
    return uri.replace(scheme: 'https', host: frontend).toString();
  }

  /// Shows a persistent SnackBar when the native layer auto-detects a new ad host.
  /// The user can tap "Block" to confirm adding it, or "Dismiss" to ignore.
  void _showDetectedAdHostBanner(String host) {
    if (_detectedAdHosts.contains(host)) return; // already shown
    _detectedAdHosts.add(host);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 12),
        content: Text('New ad host detected: $host'),
        action: SnackBarAction(
          label: 'Block it',
          onPressed: () {
            addAdHost(host);
            messenger.showSnackBar(
              SnackBar(
                content: Text('$host added to blocklist'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Adds [host] to the runtime ad-host list and persists it.
  Future<bool> addAdHost(String host) async {
    if (!Platform.isAndroid) return false;
    try {
      final added = await _adBlockChannel.invokeMethod<bool>('addHost', {'host': host});
      return added ?? false;
    } catch (_) { return false; }
  }

  /// Removes [host] from the runtime ad-host list and persists the change.
  Future<bool> removeAdHost(String host) async {
    if (!Platform.isAndroid) return false;
    try {
      final removed = await _adBlockChannel.invokeMethod<bool>('removeHost', {'host': host});
      return removed ?? false;
    } catch (_) { return false; }
  }

  /// Returns only custom (user-added + auto-detected) ad hosts.
  Future<List<String>> getAdHosts() async {
    if (!Platform.isAndroid) return [];
    try {
      final list = await _adBlockChannel.invokeMethod<List>('getCustomHosts');
      return list?.cast<String>() ?? [];
    } catch (_) { return []; }
  }

  Future<void> setAdBlockEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    setState(() => _adBlockEnabled = enabled);
    try {
      await _adBlockChannel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  /// Inject the YouTube ad-blocker. Designed to be safe to call from
  /// onPageStarted (DOM may not exist yet) — DOM-dependent setup is deferred
  /// until DOMContentLoaded.
  ///
  /// The core trick is the same as Brave / uBlock Origin's `json-prune`
  /// scriptlet: YouTube's player decides when to splice ads into the stream
  /// by reading specific fields on the player config blob. If those fields
  /// are gone before the player reads them, no ads get inserted.
  ///   * `window.ytInitialPlayerResponse` — set inline on first page load.
  ///     We define a property setter that strips ad fields on assignment.
  ///   * `/youtubei/v1/player` API responses — fetched for every video
  ///     navigated to inside the SPA. We wrap fetch and prune the JSON.
  ///
  /// CSS hiding and the skip-button click observer are kept as defence in
  /// depth (in case YouTube renames the ad fields and pruning breaks).
  /// Runs the frame agent straight into the main frame of [ctrl].
  ///
  /// The document-start registration reaches every frame and runs before the
  /// page's own scripts, which is strictly better — but on a device where that
  /// registration does not take, it leaves nothing at all. The agent guards
  /// itself with `window.__cupFrameBoot`, so where both routes work the second
  /// one does nothing, and where only this one works the page still gets the
  /// ad pruning. It returns immediately in a top frame after that, so none of
  /// the frame-agent machinery runs twice.
  void _injectFrameAgentIntoMainFrame([WebViewController? ctrl]) {
    final src = _frameScriptSource;
    if (src == null || src.trim().isEmpty) return;
    try {
      (ctrl ?? _controller).runJavaScript(src);
    } catch (_) {
      // A page that rejects it keeps whatever the injected blocker below gives
      // it; this is the better copy, not the only one.
    }
  }

  void _injectYouTubeAdBlocker([WebViewController? ctrl]) {
    // Before the copy below, so the flag it sets makes that copy stand its
    // pruning down. This one covers the mobile site's get_watch endpoint and
    // XHR, which the copy below does not.
    _injectFrameAgentIntoMainFrame(ctrl);
    const js = r'''
      (function() {
        if (!location.hostname.includes('youtube.com')) return;
        if (window._ytAdBlockerInjected) return;
        window._ytAdBlockerInjected = true;

        // Says which of the two copies is doing the work. Without it, a page
        // the frame agent missed and a page nothing ran on at all read the
        // same in the log — silence.
        try {
          SnippetLogChannel.postMessage('log|[yt] host injection ran, prune ' +
            (window._ytAdPruneInstalled ? 'already up (frame agent)' : 'installing here'));
        } catch (_) {}

        // ---- 1. JSON pruning (the actual ad killer) ----
        // Stood down when the frame agent installed the same prune first. It
        // runs at document start in every frame, so where it is present it is
        // strictly the better copy — and wrapping fetch twice would parse and
        // re-serialise every player response for nothing. The DOM defences
        // below still run either way; the frame agent has no equivalent.
        if (!window._ytAdPruneInstalled) {
        window._ytAdPruneInstalled = 1;

        const AD_KEYS = [
          'playerAds', 'adPlacements', 'adSlots', 'adServingData',
          'adBreakHeartbeatParams', 'importantForAds',
        ];
        function prune(obj) {
          if (!obj || typeof obj !== 'object') return;
          for (const k of AD_KEYS) {
            if (k in obj) try { delete obj[k]; } catch (_) {}
          }
          // Responses to /next and the reel endpoint carry the player response
          // one level down rather than at the top, and that copy holds its own
          // ad keys. Descend by name rather than walking the whole tree: the
          // payload is large, and deleting a key called adSlots wherever it
          // happens to appear risks taking a part of the page with it.
          if (obj.playerResponse) prune(obj.playerResponse);
        }

        // Best-effort: prune anything already assigned by an inline <script>
        // that ran before us (we sometimes lose the race since webview_flutter
        // can't inject at document-start).
        try { prune(window.ytInitialPlayerResponse); } catch (_) {}

        // Property setter for future assignments. The watch-page inline
        // script assigns this; SPA navigations re-assign it after fetching.
        try {
          let _ipr = window.ytInitialPlayerResponse;
          Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            set(v) { prune(v); _ipr = v; },
            get() { return _ipr; },
          });
        } catch (_) { /* property may already be non-configurable */ }

        // Wrap fetch so the innertube responses that carry ad data (issued for
        // every SPA video navigation) get the same treatment. This is the path
        // that catches every video after the first one on a session.
        const AD_ENDPOINTS = [
          '/youtubei/v1/player',
          '/youtubei/v1/next',
          '/youtubei/v1/reel/reel_item_watch',
        ];
        function carriesAds(url) {
          return AD_ENDPOINTS.some((p) => url.includes(p));
        }
        const _origFetch = window.fetch;
        window.fetch = async function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          const response = await _origFetch.call(this, input, init);
          if (carriesAds(url)) {
            try {
              const text = await response.clone().text();
              const json = JSON.parse(text);
              prune(json);
              return new Response(JSON.stringify(json), {
                status: response.status,
                statusText: response.statusText,
                headers: response.headers,
              });
            } catch (_) { return response; }
          }
          return response;
        };
        } // end of the prune install

        // ---- 2. Defensive CSS + skip-button click observer ----
        // Runs after DOMContentLoaded so we don't fail when injected at
        // document-start (no document.head yet).
        function setupDom() {
          const style = document.createElement('style');
          // Marks the element as ours, so "Save page HTML" can strip it.
          style.setAttribute('data-cupitor-injected', '');
          style.textContent = `
            .ytp-ad-overlay-container,
            .ytp-ad-player-overlay,
            .ytp-ad-player-overlay-instream-info,
            .ytp-ad-image-overlay,
            .ytp-ad-text-overlay,
            .ytp-ad-module,
            .ytp-ad-action-interstitial,
            .ytp-ad-skip-button-slot,
            ytd-action-companion-ad-renderer,
            ytd-display-ad-renderer,
            ytd-video-masthead-ad-renderer,
            ytd-promoted-sparkles-web-renderer,
            ytd-banner-promo-renderer,
            ytd-ad-slot-renderer,
            yt-mealbar-promo-renderer,
            #masthead-ad,
            #player-ads { display: none !important; }
          `;
          (document.head || document.documentElement).appendChild(style);

          function clickSkip() {
            const btn = document.querySelector(
              '.ytp-skip-ad-button, .ytp-ad-skip-button, ' +
              '.ytp-skip-ad-button-modern, .ytp-ad-skip-button-modern, ' +
              '.ytp-ad-skip-button-slot button, .ytp-ad-overlay-close-button'
            );
            if (btn) btn.click();
          }

          function attach(player) {
            if (player._ytAdObserverAttached) return;
            player._ytAdObserverAttached = true;
            new MutationObserver((mutations) => {
              for (const m of mutations) {
                if (m.type !== 'childList') continue;
                for (const node of m.addedNodes) {
                  if (node.nodeType !== 1) continue;
                  if (node.matches && node.matches(
                    '.ytp-skip-ad-button, .ytp-ad-skip-button, ' +
                    '.ytp-skip-ad-button-modern, .ytp-ad-skip-button-modern, ' +
                    '.ytp-ad-skip-button-slot'
                  )) { clickSkip(); return; }
                }
              }
            }).observe(player, { childList: true, subtree: true });
          }

          const existing = document.querySelector('.html5-video-player');
          if (existing) {
            attach(existing);
          } else {
            const bootstrap = new MutationObserver(() => {
              const p = document.querySelector('.html5-video-player');
              if (p) { bootstrap.disconnect(); attach(p); }
            });
            bootstrap.observe(document.documentElement, { childList: true, subtree: true });
          }
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', setupDom, { once: true });
        } else {
          setupDom();
        }
      })();
    ''';
    (ctrl ?? _controller).runJavaScript(js);
  }

  Future<void> _injectAdBlocker([WebViewController? ctrl]) async {
    const css = '''
      (function() {
        if (window._adBlockerInjected) return;
        window._adBlockerInjected = true;
        const style = document.createElement('style');
        // Marks the element as ours, so "Save page HTML" can strip it.
        style.setAttribute('data-cupitor-injected', '');
        style.textContent = `
          /* Common ad containers */
          ins.adsbygoogle,
          [id*="google_ads"],
          [id*="div-gpt-ad"],
          [class*="adsbygoogle"],
          [class*="ad-banner"],
          [class*="ad-container"],
          [class*="ad-wrapper"],
          [class*="ad-slot"],
          [class*="banner-ad"],
          [class*="sponsored"],
          [data-ad-slot],
          [data-ad-unit],
          iframe[src*="googlesyndication"],
          iframe[src*="doubleclick"],
          iframe[src*="adservice"],
          iframe[src*="amazon-adsystem"],
          iframe[src*="ads."],
          script[src*="pagead2.googlesyndication"],
          /* sticky/floating ad bars */
          [id*="sticky-ad"],
          [class*="sticky-ad"],
          [class*="float-ad"],
          [class*="overlay-ad"],
          [class*="interstitial"],
          /* generic heuristics */
          [class*="pub_300x250"],
          [class*="pub_728x90"],
          [id*="AdDiv"],
          [id*="ad_box"],
          [id*="ad_unit"] {
            display: none !important;
            visibility: hidden !important;
            height: 0 !important;
            min-height: 0 !important;
            overflow: hidden !important;
          }
        `;
        document.head.appendChild(style);

        // Block known ad scripts from running
        const adHosts = [
          'googlesyndication.com', 'doubleclick.net', 'googleadservices.com',
          'adnxs.com', 'advertising.com', 'amazon-adsystem.com',
          'ads.yahoo.com', 'taboola.com', 'outbrain.com', 'moatads.com',
          'adsafeprotected.com', 'scorecardresearch.com', 'pubads.g.doubleclick.net',
        ];
        // Redirect blocked URLs to a harmless data: URL instead of swallowing
        // open()/send(). Swallowing leaves the XHR in an invalid state and the
        // caller waiting forever for onload/onreadystatechange — which hangs the
        // whole WebView when scripts await ad-tracker XHRs synchronously.
        const _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          const target = (typeof url === 'string' && adHosts.some(h => url.includes(h)))
            ? 'data:text/plain,' : url;
          return _open.call(this, method, target, ...rest);
        };
        const _fetch = window.fetch;
        window.fetch = function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          if (adHosts.some(h => url.includes(h))) return Promise.resolve(new Response('', { status: 200 }));
          return _fetch.call(this, input, init);
        };
      })();
    ''';
    (ctrl ?? _controller).runJavaScript(css);
  }

  String _normalizeUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    // Looks like a URL if it has no spaces and contains a dot (e.g. google.com, sub.domain.com/path)
    final looksLikeUrl = !trimmed.contains(' ') && trimmed.contains('.');
    if (looksLikeUrl) {
      return 'https://$trimmed';
    }
    // Otherwise treat as a Google search query
    return 'https://www.google.com/search?q=${Uri.encodeComponent(trimmed)}';
  }

  Future<void> _addBookmark() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _bookmarks.contains(url)) return;
    setState(() => _bookmarks.insert(0, url));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bookmarks', _bookmarks);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Bookmarked'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _removeBookmark(String url) async {
    setState(() {
      _bookmarks.remove(url);
      _bookmarkNames.remove(url);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('bookmarks', _bookmarks);
    await prefs.setString('bookmarkNames', jsonEncode(_bookmarkNames));
  }

  Future<void> _renameBookmark(String url, String name) async {
    setState(() {
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        _bookmarkNames.remove(url);
      } else {
        _bookmarkNames[url] = trimmed;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bookmarkNames', jsonEncode(_bookmarkNames));
  }

  Future<void> _showRenameBookmarkDialog(String url) async {
    final controller = TextEditingController(text: _bookmarkNames[url] ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename bookmark'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Name (leave empty to reset)',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await _renameBookmark(url, result);
  }

  // Section header + spacer helpers for the Tools drawer. Keeping them
  // separate methods so the ListView body stays readable — each group
  // is one visual chunk with a labelled top row.
  Widget _toolsSectionHeader(String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _toolsSectionDivider() => const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Divider(height: 1),
      );

  /// Asks how the page should be saved, then saves it.
  ///
  /// The choice is put here rather than left as a switch elsewhere in Tools
  /// because it only means anything at this moment, and it decides what the
  /// file contains. The answer is remembered as the next save's default, so
  /// someone who always wants one of them is asked a question they can pass
  /// straight through.
  Future<void> _showSavePageHtmlDialog() async {
    var strip = _savePageStrip;
    final go = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialogState) => AlertDialog(
          title: const Text('Save page HTML'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The page as it stands now, to a file you pick.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: strip,
                title: const Text("Strip Cupitor's markup"),
                subtitle: Text(strip
                    ? 'Saved as the site rendered it'
                    : "Saved with Cupitor's own markup included"),
                onChanged: (val) => setDialogState(() => strip = val ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Save…'),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    // Remembered from here on, not from the tick: a box flipped and then
    // cancelled said nothing about what the next save should do. Backing out
    // of the file picker after this point still leaves the answer standing,
    // which is the question the user did answer.
    if (strip != _savePageStrip) {
      setState(() => _savePageStrip = strip);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('savePageStripCupitor', strip);
    }
    await _savePageHtml(strip: strip);
  }

  /// "Save page HTML…": the main WebView's document as rendered, to a file
  /// the user picks. With [strip] every addition Cupitor made to the page is
  /// taken out first, so the file is the page as the site rendered it — see
  /// assets/js/page_export.js for what that covers.
  Future<void> _savePageHtml({required bool strip}) async {
    try {
      // Injected on demand; the page never needs this otherwise.
      final js = await rootBundle.loadString('assets/js/page_export.js');
      await _controller.runJavaScript(js);
      final raw = await _controller.runJavaScriptReturningResult(
        'window.__cupitorExportHtml(${strip ? 'true' : 'false'})',
      );
      // Android hands back a JSON-encoded string; anything that is not
      // valid JSON is taken verbatim. Never quote-stripped — it is HTML.
      // A JS error or an undefined result comes back as the string `null`,
      // which is nothing to save rather than a four-byte file.
      var html = raw.toString();
      try {
        final decoded = jsonDecode(html);
        if (decoded is String) html = decoded;
        if (decoded == null) html = '';
      } catch (_) {}
      if (html.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to save')),
        );
        return;
      }
      final url = await _controller.currentUrl() ?? '';
      final host = Uri.tryParse(url)?.host ?? '';
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp =
          '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
      final fileName = '${host.isEmpty ? 'page' : host}-$stamp.html';
      if (!mounted) return;
      final savedPath = await saveBytesToPickedFile(
        dialogTitle: 'Save page HTML',
        fileName: fileName,
        bytes: utf8.encode(html),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          savedPath == null ? 'Save cancelled' : 'Saved: $savedPath',
        )),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  void _showToolsDrawer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Text('Tools', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Spacer(),
                    IconButton(
                      icon: Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    // ── Reading & content ──────────────────────────────
                    // First, because it is what the app is for. Everything
                    // below it adjusts how reading works rather than doing it.
                    _toolsSectionHeader('Reading & content'),
                    ListTile(
                      leading: const Icon(Icons.bookmarks_outlined),
                      title: const Text('Bookmarks'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showBookmarks();
                      },
                    ),
                    if (_tagDbReady)
                      ListTile(
                        leading: const Icon(Icons.label_outline),
                        title: const Text('Tag sentences…'),
                        subtitle: const Text(
                          'Capture chip, masks, filter, segmentation scope, '
                          'and the global browser — all in one place.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _openTagSettingsSheet();
                        },
                      ),

                    // ── Books ──────────────────────────────────────────
                    // Opening a book, returning to one, and searching across
                    // all of them are the same errand at different stages.
                    _toolsSectionDivider(),
                    _toolsSectionHeader('Books'),
                    ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: const Text('Open EPUB'),
                      subtitle: const Text('From device storage or a URL'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showEpubSourcePicker();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.history_edu_outlined),
                      title: const Text('EPUB library'),
                      subtitle: const Text('Resume a recent book'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showEpubLibrary();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.search),
                      title: const Text('Global search…'),
                      subtitle: const Text(
                        'Across every EPUB · use `|` for OR (e.g. cat|dog)',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _openGlobalSearch();
                      },
                    ),

                    // ── Appearance ─────────────────────────────────────
                    _toolsSectionDivider(),
                    _toolsSectionHeader('Appearance'),
                    SwitchListTile(
                      secondary: Icon(_isEinkMode ? Icons.invert_colors_off : Icons.invert_colors),
                      title: const Text('E-ink mode'),
                      subtitle: const Text('High-contrast reading'),
                      value: _isEinkMode,
                      onChanged: (val) {
                        setState(() => _isEinkMode = val);
                        einkMode.value = val;
                        setModalState(() {});
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.format_size),
                      title: const Text('Page font size'),
                      subtitle: Text('${(100 * (1.0 + _pageZoomLevel * 0.15)).round()}%'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.text_decrease),
                            tooltip: 'Decrease',
                            onPressed: () async {
                              await _changePageZoom(-1);
                              setModalState(() {});
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.text_increase),
                            tooltip: 'Increase',
                            onPressed: () async {
                              await _changePageZoom(1);
                              setModalState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    if (_currentPdfUrl != null) ...[
                      ListTile(
                        leading: const Icon(Icons.zoom_out),
                        title: const Text('PDF zoom out'),
                        onTap: () => _changePdfZoom(-1),
                      ),
                      ListTile(
                        leading: const Icon(Icons.zoom_in),
                        title: const Text('PDF zoom in'),
                        onTap: () => _changePdfZoom(1),
                      ),
                    ],

                    // ── Web behavior ───────────────────────────────────
                    _toolsSectionDivider(),
                    _toolsSectionHeader('Web behavior'),
                    ListTile(
                      leading: const Icon(Icons.history),
                      title: const Text('History'),
                      subtitle: const Text(
                        'Pages you have visited. Search, remove, or clear.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        Navigator.of(ctx).pop();
                        final picked = await Navigator.of(context)
                            .push<String>(MaterialPageRoute<String>(
                          builder: (_) => const HistoryScreen(),
                        ));
                        if (picked == null || !mounted) return;
                        _urlController.text = picked;
                        _loadUrl();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: const Text('Language'),
                      trailing: DropdownButton<String>(
                        value: _selectedLanguage,
                        items: _languages
                            .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            _selectedLanguage = val!;
                            if (dialogController != null) {
                              dialogController?.loadRequest(
                                  Uri.parse(getUrlForLanguage(_selectedLanguage)));
                            }
                          });
                          setModalState(() {});
                        },
                        underline: const SizedBox(),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.smart_display_outlined),
                      title: const Text('YouTube playback'),
                      subtitle: Text(_youtubeFrontend == null
                          ? 'Native YouTube (with ad blocker)'
                          : 'Via ${_youtubeFrontend!}'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showYoutubeFrontendPicker();
                      },
                    ),
                    // The one choice that changes what lands in the file is
                    // asked on the way out, where it is being made — not kept
                    // as a separate switch to find and set beforehand.
                    ListTile(
                      leading: const Icon(Icons.save_alt_outlined),
                      title: const Text('Save page HTML…'),
                      subtitle: Text(_savePageStrip
                          ? "As the site rendered it, Cupitor's markup stripped"
                          : "Exactly as it stands, Cupitor's markup included"),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showSavePageHtmlDialog();
                      },
                    ),

                    // ── Exclusions & blocking ──────────────────────────
                    // Both name what Cupitor should leave alone, one for its
                    // own features and one for the network.
                    _toolsSectionDivider(),
                    _toolsSectionHeader('Exclusions & blocking'),
                    ValueListenableBuilder<List<String>>(
                      valueListenable: LookupExclusions.patterns,
                      builder: (_, list, __) => ListTile(
                        leading: const Icon(Icons.block),
                        title: const Text('Lookup exclusions…'),
                        subtitle: Text(
                          list.isEmpty
                              ? 'No sites excluded'
                              : '${list.length} pattern${list.length == 1 ? '' : 's'} — '
                                  'word-lookup / tagging skipped',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const LookupExclusionsScreen(),
                          ));
                        },
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.security_outlined),
                      title: const Text('Ad hosts'),
                      subtitle: const Text('Manage blocked ad hosts'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showAdHosts();
                      },
                    ),

                    // ── Advanced ───────────────────────────────────────
                    _toolsSectionDivider(),
                    _toolsSectionHeader('Advanced'),
                    ListTile(
                      leading: Icon(_githubToken != null ? Icons.key : Icons.key_off_outlined),
                      title: const Text('GitHub token'),
                      subtitle: Text(_githubToken != null ? 'Token set' : 'Not configured'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showTokenDialog();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.auto_awesome),
                      title: const Text('AI prompt'),
                      subtitle: Text(
                        _aiPromptTemplate == kDefaultAiPromptTemplate
                            ? 'Default wording'
                            : 'Customised',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showAiPromptDialog();
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.memory),
                      title: const Text('Memory manager'),
                      subtitle: const Text(
                        'Storage overview per book, orphan-file cleanup, and '
                        '.cupitor.zip import.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const MemoryManagerScreen(),
                        ));
                      },
                    ),
                    ListTile(
                      leading: Icon(_tagCaptureArmed
                          ? Icons.playlist_add_check
                          : Icons.playlist_add),
                      title: const Text('Collect sentences'),
                      subtitle: const Text(
                          'Tap sentences on the page, then Send to a playlist'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _armSentenceCollecting();
                      },
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.edit_note),
                      title: const Text('Video note button'),
                      subtitle: const Text(
                          'Floating button on videos: type or dictate a note '
                          'at the current time, send it to a playlist'),
                      value: _videoNoteEnabled,
                      onChanged: (val) async {
                        await _setVideoNoteEnabled(val);
                        setModalState(() {});
                      },
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.fullscreen),
                      title: const Text('Fullscreen study button'),
                      subtitle: const Text(
                          'Floating button that opens the study dialog in fullscreen'),
                      value: _studyFsChipEnabled,
                      onChanged: (val) async {
                        await _setStudyFsChipEnabled(val);
                        setModalState(() {});
                      },
                    ),

                    // ── Diagnostics ────────────────────────────────────
                    // Run something against the page, watch what it does,
                    // read what it said — in that order, because that is the
                    // order they are used in.
                    _toolsSectionDivider(),
                    _toolsSectionHeader('Diagnostics'),
                    ListTile(
                      leading: const Icon(Icons.code),
                      title: const Text('Inject remote snippet'),
                      subtitle: const Text('Run remote JavaScript on current page'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _injectRemoteSnippet();
                      },
                    ),
                    // Turn on while a page/modal refuses to scroll, then drag
                    // on the stuck area and read the snippet logs. Listeners
                    // are all passive, so arming it can't change behaviour.
                    SwitchListTile(
                      secondary: Icon(_scrollDiagEnabled
                          ? Icons.swipe_vertical
                          : Icons.swipe_vertical_outlined),
                      title: const Text('Scroll diagnostics'),
                      subtitle: Text(_scrollDiagEnabled
                          ? 'Armed — drag on the stuck area, then view snippet logs'
                          : 'Log why a page or modal will not scroll'),
                      value: _scrollDiagEnabled,
                      onChanged: (val) async {
                        await _setScrollDiagnostics(val);
                        setModalState(() {});
                      },
                    ),
                    if (_scrollDiagEnabled)
                      ListTile(
                        leading: const Icon(Icons.camera_alt_outlined),
                        title: const Text('Scroll snapshot now'),
                        subtitle: const Text(
                            'Dump overflow / transform / covering elements'),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _snapshotScrollDiag();
                        },
                      ),
                    ListTile(
                      leading: const Icon(Icons.terminal),
                      title: const Text('View snippet logs'),
                      subtitle: Text('${_snippetLogs.length} entries'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _showSnippetLogs();
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── EPUB reader integration ────────────────────────────────────────────
  // The reader lives in [lib/epub_reader.dart]. We pull EPUB files from
  // three sources (device storage, an HTTP/HTTPS URL, a link in the main
  // WebView that ends in .epub), cache them under <docs>/epubs/, and push
  // the reader screen. Word-tap and selection callbacks from the reader
  // route into the existing dictionary flow via [_openDialogWithWebview],
  // so the EPUB inherits all of Cupitor's lookup machinery for free.

  EpubLibrary? _epubLibrary;

  Future<EpubLibrary> _ensureEpubLibrary() async {
    return _epubLibrary ??= await EpubLibrary.load();
  }

  Future<void> _launchEpubReader(File file, {String? initialHighlight}) async {
    final lib = await _ensureEpubLibrary();
    if (!mounted) return;
    await openEpubReader(
      context,
      file: file,
      library: lib,
      initialHighlight: initialHighlight,
      onLookup: (word, _) {
        // Send the looked-up word into the existing lookup flow. The
        // surrounding context is discarded for now — dialog1 only takes
        // a query string. Could be threaded through later if we want to
        // pre-fill a "context" field.
        _openDialogWithWebview(word);
      },
      onSendToPlaylist: ({required text, required title, required url}) =>
          _sendSentenceToWebappPlaylist(text: text, title: title, url: url),
    );
  }

  void _showEpubSourcePicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Open EPUB',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('From device storage'),
              subtitle: const Text('Pick a .epub file'),
              onTap: () async {
                Navigator.of(ctx).pop();
                try {
                  final f = await pickEpubFromDevice();
                  if (f != null) await _launchEpubReader(f);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not pick file: $e')),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('From URL'),
              subtitle: const Text('Download and open'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _promptEpubUrlAndOpen();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptEpubUrlAndOpen() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open EPUB from URL'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/book.epub',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _downloadAndOpenEpub(url);
  }

  Future<void> _downloadAndOpenEpub(String url) async {
    // Show an indeterminate progress dialog while the file downloads. It's
    // dismissed in `finally` so a network error doesn't leave it stuck.
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(width: 16),
              Text('Downloading EPUB…'),
            ],
          ),
        ),
      ),
    );
    try {
      final f = await downloadEpubFromUrl(url);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      if (f != null) await _launchEpubReader(f);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not download EPUB: $e')),
      );
    }
  }

  Future<void> _showEpubLibrary() async {
    final lib = await _ensureEpubLibrary();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: const [
                    Text('EPUB library',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: lib.entries.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No books yet. Use Open EPUB to add one.'),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: lib.entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final e = lib.entries[i];
                          return ListTile(
                            leading: SizedBox(
                              width: 40,
                              height: 56,
                              child: _epubCoverThumbnail(e),
                            ),
                            title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(e.author ?? e.path,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Remove from library',
                              onPressed: () async {
                                await lib.remove(e.key);
                                setSheet(() {});
                              },
                            ),
                            onTap: () async {
                              Navigator.of(ctx).pop();
                              final f = File(e.path);
                              if (!await f.exists()) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('File missing: ${e.path}')),
                                );
                                return;
                              }
                              await _launchEpubReader(f);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Library-row thumbnail — book cover if present, fallback icon otherwise.
  /// Wrapped in a small frame so the row layout is stable even when the
  /// cover file is missing (e.g. an old library entry from before covers
  /// were stored).
  Widget _epubCoverThumbnail(EpubLibraryEntry e) {
    final p = e.coverPath;
    if (p != null) {
      final f = File(p);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _epubCoverPlaceholder(),
          ),
        );
      }
    }
    return _epubCoverPlaceholder();
  }

  Widget _epubCoverPlaceholder() => Container(
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Icon(Icons.menu_book_outlined, size: 22, color: Colors.grey),
      );

  // True if a URL likely points to an EPUB. Cheap path-extension check —
  // mirrors `_looksLikePdfUrl` so the navigation delegate can short-circuit
  // before WebView opens the file as a download.
  bool _looksLikeEpubUrl(String url) {
    final lower = url.toLowerCase();
    final qPos = lower.indexOf('?');
    final path = qPos >= 0 ? lower.substring(0, qPos) : lower;
    return path.endsWith('.epub');
  }

  void _showYoutubeFrontendPicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'YouTube playback',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Native uses youtube.com with our JSON-prune ad blocker. Front-ends serve YouTube content with no ads at all but may go offline; pick a fallback if your usual one stops working.',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ),
            RadioListTile<String?>(
              title: Text('Native YouTube'),
              subtitle: Text('Real youtube.com, our ad blocker strips ads'),
              value: null,
              groupValue: _youtubeFrontend,
              onChanged: (v) async {
                Navigator.of(ctx).pop();
                await _setYoutubeFrontend(v);
              },
            ),
            ..._youtubeFrontendInstances.map((host) => RadioListTile<String?>(
                  title: Text(host),
                  value: host,
                  groupValue: _youtubeFrontend,
                  onChanged: (v) async {
                    Navigator.of(ctx).pop();
                    await _setYoutubeFrontend(v);
                  },
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _setYoutubeFrontend(String? value) async {
    setState(() => _youtubeFrontend = value);
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove('youtubeFrontend');
    } else {
      await prefs.setString('youtubeFrontend', value);
    }
  }

  void _showAdHosts() {
    List<String> hosts = [];
    bool loading = true;
    bool initDone = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> loadHosts() async {
            final list = await getAdHosts();
            setModalState(() {
              hosts = list;
              loading = false;
            });
          }

          if (!initDone) {
            initDone = true;
            loadHosts();
          }

          return DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.security_outlined),
                      SizedBox(width: 8),
                      Text('Ad Hosts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      Spacer(),
                      Switch(
                        value: _adBlockEnabled,
                        onChanged: (val) async {
                          await setAdBlockEnabled(val);
                          setModalState(() {});
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline),
                        tooltip: 'Add host',
                        onPressed: () {
                          final ctrl = TextEditingController();
                          showDialog(
                            context: ctx,
                            builder: (dlgCtx) => AlertDialog(
                              title: Text('Add ad host'),
                              content: TextField(
                                controller: ctrl,
                                autofocus: true,
                                decoration: InputDecoration(
                                  hintText: 'e.g. ads.example.com',
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (_) async {
                                  final h = ctrl.text.trim().toLowerCase();
                                  if (h.isEmpty) return;
                                  Navigator.of(dlgCtx).pop();
                                  await addAdHost(h);
                                  loadHosts();
                                },
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(dlgCtx).pop(),
                                  child: Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final h = ctrl.text.trim().toLowerCase();
                                    if (h.isEmpty) return;
                                    Navigator.of(dlgCtx).pop();
                                    await addAdHost(h);
                                    loadHosts();
                                  },
                                  child: Text('Add'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: loading
                      ? Center(child: CircularProgressIndicator())
                      : hosts.isEmpty
                          ? Center(child: Text('No ad hosts configured'))
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: hosts.length,
                              itemBuilder: (_, i) {
                                final host = hosts[i];
                                return ListTile(
                                  leading: Icon(Icons.block, size: 20),
                                  title: Text(host,
                                      style: TextStyle(fontFamily: 'monospace', fontSize: 13)),
                                  trailing: IconButton(
                                    icon: Icon(Icons.delete_outline),
                                    tooltip: 'Remove',
                                    onPressed: () async {
                                      await removeAdHost(host);
                                      loadHosts();
                                    },
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showBookmarks() {    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Text('Bookmarks', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Spacer(),
                    IconButton(
                      icon: Icon(Icons.bookmark_add_outlined),
                      tooltip: 'Add current page',
                      onPressed: () async {
                        final url = _urlController.text.trim();
                        if (url.isEmpty || _bookmarks.contains(url)) return;
                        setState(() => _bookmarks.insert(0, url));
                        setModalState(() {});
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setStringList('bookmarks', _bookmarks);
                      },
                    ),
                    if (_bookmarks.isNotEmpty)
                      TextButton(
                        child: Text('Clear all'),
                        onPressed: () async {
                          setState(() {
                            _bookmarks.clear();
                            _bookmarkNames.clear();
                          });
                          setModalState(() {});
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setStringList('bookmarks', []);
                          await prefs.setString('bookmarkNames', jsonEncode({}));
                        },
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _bookmarks.isEmpty
                    ? Center(child: Text('No bookmarks yet'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _bookmarks.length,
                        itemBuilder: (_, i) {
                          final url = _bookmarks[i];
                          final name = _bookmarkNames[url];
                          return ListTile(
                            leading: Icon(Icons.bookmark),
                            title: Text(name ?? url, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: name != null
                                ? Text(url, maxLines: 1, overflow: TextOverflow.ellipsis)
                                : null,
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _urlController.text = url;
                              _loadUrl();
                            },
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.edit_outlined),
                                  tooltip: 'Rename',
                                  onPressed: () async {
                                    await _showRenameBookmarkDialog(url);
                                    setModalState(() {});
                                  },
                                ),
                                IconButton(
                                  icon: Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    await _removeBookmark(url);
                                    setModalState(() {});
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _loadUrl() async {
    final url = _normalizeUrl(_urlController.text);
    final uri = Uri.tryParse(url);
    if (uri != null && uri.isAbsolute) {
      _urlController.text = url;
      _controller.loadRequest(uri);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastUrl', url);
    }
  }

  /// Strip language-specific suffixes to get a stem for wiktionary search.
  String _stemWord(String word, String lang) {
    word = word.toLowerCase().trim();
    List<String> suffixes;
    switch (lang) {
      case 'sv':
        // Swedish: remove common inflectional suffixes (longest first)
        suffixes = ['ighet', 'ande', 'arna', 'erna', 'ning', 'het', 'ade', 'ade', 'ing',
                     'are', 'ast', 'ade', 'ar', 'or', 'er', 'en', 'et', 'na', 'de', 'te',
                     'ad', 'at', 's', 't', 'a', 'e'];
        break;
      case 'es':
        // Spanish
        suffixes = ['iones', 'ción', 'ando', 'endo', 'ados', 'idas', 'ado', 'ido',
                     'aba', 'ían', 'mente', 'es', 'os', 'as', 'an', 'en', 'ó', 's'];
        break;
      default:
        suffixes = ['ing', 'tion', 'ed', 'ly', 'er', 'est', 's'];
    }
    for (final s in suffixes) {
      if (word.endsWith(s) && word.length - s.length >= 2) {
        return word.substring(0, word.length - s.length);
      }
    }
    return word;
  }

  void _openDialog2WithWebview(String url) {
    // Pre-rewrite YouTube URLs to the chosen front-end. Cheap to call when no
    // front-end is configured (returns null).
    url = _rewriteYouTubeUrl(url) ?? url;
    // Every fresh Wiktionary dialog starts with collect mode OFF — a stale
    // toggle from a previous dialog would silently swallow normal clicks here.
    // Also reset the captured-words list so a new lookup session starts with
    // a clean slate; the user explicitly opted into capture for the previous
    // session, and silently mixing those words into a new one would surprise
    // them. Persist immediately so the empty state survives an app restart.
    if (_isWiktionaryUrl(url)) {
      if (_wiktCollectMode.value) _wiktCollectMode.value = false;
      if (_wiktCollectedWords.value.isNotEmpty) {
        _wiktCollectedWords.value = <String>[];
        _persistWiktCollectedWords();
      }
    }
    // Create unique dialog ID based on URL and timestamp
    final dialogId = '${Uri.parse(url).host}_${DateTime.now().millisecondsSinceEpoch}';

    final errorNotifier = ValueNotifier<String?>(null);
    bool hasRedirected = false;
    final String dialogIdForBridge = dialogId;
    late final WebViewController dialog2Controller;
    dialog2Controller = WebViewController()
      ..configureForMac()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_userAgent)
      ..addJavaScriptChannel('FilmotBridge', onMessageReceived: (msg) => _handleFilmotMessage(dialogIdForBridge, msg.message))
      ..addJavaScriptChannel('WiktCollect', onMessageReceived: (msg) => _handleWiktCollectMessage(msg.message))
      ..addJavaScriptChannel('LinkLongPress', onMessageReceived: (msg) => _handleLinkLongPress(msg.message))
      // Shared log sink — without it the scroll probe's output from this
      // WebView would be thrown away by its own try/catch.
      ..addJavaScriptChannel('SnippetLogChannel',
          onMessageReceived: _onSnippetLogMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (!request.isMainFrame) return NavigationDecision.navigate;
          final rewritten = _rewriteYouTubeUrl(request.url);
          if (rewritten != null) {
            dialog2Controller.loadRequest(Uri.parse(rewritten));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (_) {
          errorNotifier.value = null;
          _injectYouTubeAdBlocker(dialog2Controller);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) {
            errorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
          }
        },
        onPageFinished: (finishedUrl) {
          _injectAdBlocker(dialog2Controller);
          dialog2Controller.runJavaScript(_linkLongPressJs);
          // Auto-unmute any YouTube/HTML5 media that autoplayed muted.
          dialog2Controller.runJavaScript(_autoUnmuteYouTubeJs);
          _injectScrollDiag(dialog2Controller, 'dialog2:$dialogIdForBridge');
          if (_isFilmotUrl(finishedUrl)) {
            _injectFilmotHelper(dialog2Controller);
          }
          if (_isWiktionaryUrl(finishedUrl)) {
            // Install (idempotent) the click interceptor, then sync the
            // current toggle state — flipping the toggle later only needs
            // _pushWiktCollectMode(); no re-injection.
            dialog2Controller.runJavaScript(_wiktCollectJs);
            _pushWiktCollectMode(dialog2Controller);
          }
          // Detect wiktionary 404: /wiki/{word} page that doesn't exist
          final uri = Uri.tryParse(finishedUrl);
          if (!hasRedirected && uri != null
              && uri.host.endsWith('.wiktionary.org')
              && uri.path.startsWith('/wiki/')) {
            // Check if the page has the "no article" indicator
            dialog2Controller.runJavaScriptReturningResult(
              'document.querySelector(".noarticletext") !== null'
            ).then((result) {
              if (result.toString() == 'true') {
                hasRedirected = true;
                final word = Uri.decodeComponent(uri.path.substring('/wiki/'.length));
                final subdomain = uri.host.split('.').first;
                final stem = _stemWord(word, _selectedLanguage);
                final searchUrl = 'https://$subdomain.wiktionary.org/w/index.php?search=${Uri.encodeComponent(stem)}';
                dialog2Controller.loadRequest(Uri.parse(searchUrl));
              }
            }).catchError((_) {});
          }
        },
      ))
      ..loadRequest(Uri.parse(url));
    _enableThirdPartyCookies(dialog2Controller);

    // Store the new dialog instance
    _dialog2Controllers[dialogId] = dialog2Controller;
    _dialog2ErrorNotifiers[dialogId] = errorNotifier;
    _dialog2Urls[dialogId] = url;
    _minimizedDialog2s.remove(dialogId); // Ensure it's not marked as minimized

    _showDialog2(dialogId);
    // Same reason as dialog1: a WebView that did not exist a moment ago.
    _installRenderGuardSoon();
  }

  void _showDialog2(String dialogId) {
    final controller = _dialog2Controllers[dialogId];
    final errorNotifier = _dialog2ErrorNotifiers[dialogId];
    final url = _dialog2Urls[dialogId];
    if (controller == null || errorNotifier == null || url == null) return;

    _minimizedDialog2s.remove(dialogId); // Mark as not minimized
    _bumpMinimizedVersion();
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // If dialog has been minimized before, tapping outside should minimize, not close
    final hasBeenMinimized = _everMinimizedDialog2s.contains(dialogId);

    showDialog(
      context: context,
      barrierDismissible: !hasBeenMinimized, // Prevent outside tap closing if ever minimized
      builder: (ctx) => hasBeenMinimized
        ? GestureDetector(
            // Custom barrier tap handler - minimizes instead of closing
            onTap: () {
              _minimizedDialog2s.add(dialogId);
              Navigator.of(ctx).pop();
              _bumpMinimizedVersion();
            },
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Prevent tap propagation from dialog content
                  child: Dialog(
                    insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
                    child: _buildDialog2Content(ctx, dialogId, url, controller, errorNotifier, screenWidth, screenHeight),
                  ),
                ),
              ),
            ),
          )
        : Dialog(
            insetPadding: EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
            child: _buildDialog2Content(ctx, dialogId, url, controller, errorNotifier, screenWidth, screenHeight),
          ),
    ).then((_) {
      // Dialog closed - but keep controller alive to avoid reloading.
      // Only dispose error notifier if dialog was fully closed (not minimized).
      if (!_minimizedDialog2s.contains(dialogId)) {
        // Stop any media playback and tear down the dialog WebView's JS world.
        // Without this the YouTube player keeps running (audio + the ad-blocker's
        // MutationObserver/setInterval) after the widget is removed, which holds
        // the renderer process busy and freezes the main WebView. Navigating to
        // about:blank discards the document and stops everything in one shot.
        _shutdownDialogWebView(controller);
        errorNotifier.dispose();
        _dialog2Controllers.remove(dialogId);
        _dialog2ErrorNotifiers.remove(dialogId);
        _dialog2Urls.remove(dialogId);
        _everMinimizedDialog2s.remove(dialogId); // Clean up tracking state
        _filmotChannelsSeen.remove(dialogId);
        _chipPositions.remove(dialogId);
        _dialog2ScaffoldKeys.remove(dialogId);
      }
      _bumpMinimizedVersion();
    });
  }

  /// Stops any audio/video and unloads the document on a dialog WebView so it
  /// cannot keep working in the background after the dialog is dismissed.
  /// Safe to call even if the platform view has already been detached.
  void _shutdownDialogWebView(WebViewController controller) {
    try {
      controller.runJavaScript(
        r'try{document.querySelectorAll("video,audio").forEach(function(v){try{v.pause();v.removeAttribute("src");v.load();}catch(e){}});}catch(e){}'
      );
    } catch (_) {}
    try {
      controller.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  Widget _buildDialog2Content(BuildContext ctx, String dialogId, String url,
      WebViewController controller, ValueNotifier<String?> errorNotifier,
      double screenWidth, double screenHeight) {
    final messengerKey = _dialog2ScaffoldKeys.putIfAbsent(
      dialogId,
      () => GlobalKey<ScaffoldMessengerState>(),
    );
    return ScaffoldMessenger(
      key: messengerKey,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
      width: screenWidth * 0.98,
      height: screenHeight,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: () async {
                    if (await controller.canGoBack()) {
                      await controller.goBack();
                    } else if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No previous page'), duration: Duration(seconds: 1)),
                      );
                    }
                  },
                ),
                // Show dialog title with host name
                Expanded(
                  child: Text(
                    Uri.tryParse(url)?.host ?? 'Dialog',
                    style: TextStyle(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isWiktionaryUrl(url)) ...[
                  // Toggle: collect-clicked-words mode. When ON, the injected
                  // JS preventDefault()s link clicks and ships clicked words
                  // to Dart over the WiktCollect channel.
                  ValueListenableBuilder<bool>(
                    valueListenable: _wiktCollectMode,
                    builder: (_, on, __) => IconButton(
                      tooltip: on
                          ? 'Collect mode ON — links disabled; clicks append words'
                          : 'Collect mode OFF',
                      icon: Icon(
                        on ? Icons.touch_app : Icons.touch_app_outlined,
                        size: 20,
                        color: on ? Colors.amber : null,
                      ),
                      onPressed: () {
                        _wiktCollectMode.value = !on;
                        // Push the new flag into every open dialog2 (the
                        // listener reads it at click time, so this is enough
                        // — no re-injection needed).
                        for (final e in _dialog2Controllers.entries) {
                          if (_isWiktionaryUrl(_dialog2Urls[e.key])) {
                            _pushWiktCollectMode(e.value);
                          }
                        }
                      },
                    ),
                  ),
                  ValueListenableBuilder<List<String>>(
                    valueListenable: _wiktCollectedWords,
                    builder: (_, words, __) => Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          tooltip: 'Review collected words (${words.length})',
                          icon: const Icon(Icons.list_alt, size: 20),
                          onPressed: () => _showWiktCollectedDialog(ctx),
                        ),
                        if (words.isNotEmpty)
                          Positioned(
                            right: 4,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                              child: Text(
                                words.length > 99 ? '99+' : '${words.length}',
                                style: const TextStyle(color: Colors.white, fontSize: 9, height: 1),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_isFilmotUrl(url)) ...[
                  IconButton(
                    tooltip: 'Capture subtitle (with context, translate, send to lookup)',
                    icon: Icon(Icons.subtitles, size: 20),
                    onPressed: () => _captureFilmotSubtitle(ctx, controller),
                  ),
                  IconButton(
                    tooltip: 'Channel blacklist (tap to edit / temporarily disable)',
                    icon: Icon(Icons.block, size: 20),
                    onPressed: () => _showFilmotChannelsDialog(ctx, dialogId, controller),
                  ),
                  IconButton(
                    tooltip: 'Saved videos',
                    icon: Icon(Icons.bookmark_outline, size: 20),
                    onPressed: () => _showSavedVideosDialog(ctx),
                  ),
                  IconButton(
                    tooltip: 'Save current video URL',
                    icon: Icon(Icons.save_alt, size: 20),
                    onPressed: () => _saveCurrentFilmotVideo(dialogId, controller),
                  ),
                ],
                // `url` is the address this dialog was OPENED with and is never
                // rewritten as the user navigates, so loading it again restarts
                // the video at the `t=` the dialog1 link carried. A plain
                // reload would resume wherever the player had got to, which is
                // the opposite of what a replay button is for.
                if (isYouTubeWatchUrl(url, frontend: _youtubeFrontend))
                  IconButton(
                    tooltip: 'Replay from the start time this was opened at',
                    icon: const Icon(Icons.replay, size: 20),
                    onPressed: () {
                      final uri = Uri.tryParse(url);
                      if (uri != null) controller.loadRequest(uri);
                    },
                  ),
                IconButton(
                  tooltip: 'Minimize',
                  icon: const Icon(Icons.minimize, size: 20),
                  onPressed: () {
                    _minimizedDialog2s.add(dialogId);
                    _everMinimizedDialog2s.add(dialogId); // Mark as ever minimized
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    // Clear minimized state when manually closing
                    _minimizedDialog2s.remove(dialogId);
                    // Stop media + JS *before* popping while the platform view
                    // is still attached — `.then` cleanup may run after detach.
                    _shutdownDialogWebView(controller);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: errorNotifier,
              builder: (_, error, __) => error != null
                  ? _errorView(error, () {
                      errorNotifier.value = null;
                      controller.loadRequest(Uri.parse(url));
                    })
                  : ValueListenableBuilder<bool>(
                      valueListenable: einkMode,
                      builder: (_, eink, child) => ColorFiltered(
                        colorFilter: eink ? einkColorFilter : identityColorFilter,
                        child: child,
                      ),
                      child: pageCursor(WebViewWidget(controller: controller)),
                    ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  // ---------- Floating minimized-dialog chips ----------

  /// Inserts the overlay entry on first use; safe to call repeatedly.
  void _ensureFloatingChipsOverlay() {
    if (_floatingChipsEntry != null) return;
    _floatingChipsEntry = OverlayEntry(builder: (_) {
      return ValueListenableBuilder<int>(
        valueListenable: _minimizedVersion,
        builder: (ctx, _, __) {
          final size = MediaQuery.of(ctx).size;
          final chips = <Widget>[];
          var slot = 0;
          if (_dialog1Minimized) {
            chips.add(_buildChip(
              key: '__dialog1__',
              defaultPos: _defaultChipPos(size, slot),
              screenSize: size,
              icon: const Icon(Icons.translate, size: 18, color: Colors.white),
              label: 'Lookup',
              onTap: _showDialog1,
              onClose: () {
                setState(() {
                  _dialog1Minimized = false;
                  _dialog1EverMinimized = false;
                });
                _bumpMinimizedVersion();
              },
            ));
            slot++;
          }
          for (final dialogId in _minimizedDialog2s.toList()) {
            final url = _dialog2Urls[dialogId] ?? '';
            final host = Uri.tryParse(url)?.host ?? 'Dialog';
            final label = host.length > 14 ? host.substring(0, 14) : host;
            chips.add(_buildChip(
              key: dialogId,
              defaultPos: _defaultChipPos(size, slot),
              screenSize: size,
              icon: const Icon(Icons.menu_book, size: 18, color: Colors.white),
              label: label,
              onTap: () => _showDialog2(dialogId),
              onClose: () => _closeMinimizedDialog2(dialogId),
            ));
            slot++;
          }
          return Stack(children: chips);
        },
      );
    });
    final overlay = Overlay.of(context, rootOverlay: true);
    overlay.insert(_floatingChipsEntry!);
  }

  Offset _defaultChipPos(Size size, int slot) {
    return Offset(size.width - 140, size.height - 80 - slot * 56.0);
  }

  Widget _buildChip({
    required String key,
    required Offset defaultPos,
    required Size screenSize,
    required Widget icon,
    required String label,
    required VoidCallback onTap,
    required VoidCallback onClose,
  }) {
    return _FloatingDraggableChip(
      key: ValueKey(key),
      startPosition: _chipPositions[key] ?? defaultPos,
      screenSize: screenSize,
      icon: icon,
      label: label,
      onTap: onTap,
      onClose: onClose,
      onPositionChanged: (p) { _chipPositions[key] = p; },
    );
  }

  void _bumpMinimizedVersion() {
    _ensureFloatingChipsOverlay();
    _minimizedVersion.value++;
  }

  void _closeMinimizedDialog2(String dialogId) {
    final controller = _dialog2Controllers[dialogId];
    if (controller != null) _shutdownDialogWebView(controller);
    _dialog2ErrorNotifiers[dialogId]?.dispose();
    _dialog2Controllers.remove(dialogId);
    _dialog2ErrorNotifiers.remove(dialogId);
    _dialog2Urls.remove(dialogId);
    _minimizedDialog2s.remove(dialogId);
    _everMinimizedDialog2s.remove(dialogId);
    _filmotChannelsSeen.remove(dialogId);
    _dialog2ScaffoldKeys.remove(dialogId);
    if (mounted) setState(() {});
    _bumpMinimizedVersion();
  }

  /// Shows a SnackBar inside `dialogId`'s ScaffoldMessenger if one is alive,
  /// otherwise falls back to the root messenger. Necessary because dialog2
  /// routes cover the underlying Scaffold — root SnackBars render behind the
  /// dialog and the user never sees them.
  void _showDialog2SnackBar(String? dialogId, String message,
      {Duration duration = const Duration(seconds: 2)}) {
    final state = (dialogId != null)
        ? _dialog2ScaffoldKeys[dialogId]?.currentState
        : null;
    final snack = SnackBar(content: Text(message), duration: duration);
    if (state != null) {
      state.showSnackBar(snack);
    } else if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(snack);
    }
  }

  // ---------- Filmot helpers ----------

  bool _isFilmotUrl(String? url) {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return host.endsWith('filmot.com');
  }

  bool _isWiktionaryUrl(String? url) {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    return host.endsWith('.wiktionary.org') || host == 'wiktionary.org';
  }

  /// JS the WebView runs on every Wiktionary page load. Defines a single
  /// document-level click listener (capture phase) that reads the global
  /// `__cupWiktCollectActive` flag at click time — so flipping the toggle
  /// takes effect without re-injecting. Sends the clicked word to Dart via
  /// the `WiktCollect` channel, and preventDefault()s link navigation.
  static const String _wiktCollectJs = r'''
(function () {
  if (window.__cupWiktInstalled) return;
  window.__cupWiktInstalled = true;
  window.__cupWiktCollectActive = window.__cupWiktCollectActive || false;

  function wordAt(target, x, y) {
    // Prefer an explicit selection if the user double-tapped to select.
    try {
      var sel = window.getSelection && window.getSelection();
      if (sel && sel.toString && sel.toString().trim()) {
        return sel.toString().trim().split(/\s+/)[0];
      }
    } catch (e) {}
    // Otherwise use the caret position at the click point to extract one word.
    var node = null, offset = 0;
    if (document.caretRangeFromPoint) {
      var r = document.caretRangeFromPoint(x, y);
      if (r) { node = r.startContainer; offset = r.startOffset; }
    } else if (document.caretPositionFromPoint) {
      var p = document.caretPositionFromPoint(x, y);
      if (p) { node = p.offsetNode; offset = p.offset; }
    }
    if (node && node.nodeType === 3) {
      var t = node.textContent || '';
      var s = offset, e = offset;
      var re = /[\p{L}\p{N}\-']/u;
      while (s > 0 && re.test(t[s - 1])) s--;
      while (e < t.length && re.test(t[e])) e++;
      var w = t.substring(s, e).trim();
      if (w) return w;
    }
    // Last resort: the clicked element's text (single word only).
    var txt = (target && (target.innerText || target.textContent) || '').trim();
    return txt.split(/\s+/)[0] || '';
  }

  document.addEventListener('click', function (ev) {
    if (!window.__cupWiktCollectActive) return;
    // Block link navigation + any other default click handling.
    ev.preventDefault();
    ev.stopPropagation();
    ev.stopImmediatePropagation();
    var w = wordAt(ev.target, ev.clientX, ev.clientY);
    if (w && window.WiktCollect && window.WiktCollect.postMessage) {
      try { window.WiktCollect.postMessage(w); } catch (e) {}
    }
  }, true);

  // Visual cue: a tiny banner so the user knows clicks are being captured.
  function syncBanner() {
    var id = '__cup-wikt-banner';
    var el = document.getElementById(id);
    if (window.__cupWiktCollectActive) {
      if (!el) {
        el = document.createElement('div');
        el.id = id;
        el.style.cssText =
          'position:fixed;top:0;left:0;right:0;z-index:2147483647;'
          + 'background:#f59e0b;color:#000;font:600 12px/1.6 system-ui;'
          + 'text-align:center;padding:2px 8px;pointer-events:none;';
        el.textContent = 'Collect mode — links disabled, clicks add to word list';
        (document.body || document.documentElement).appendChild(el);
      }
    } else if (el) {
      el.remove();
    }
  }
  // Poll-light: keep the banner in sync if the flag is flipped while the
  // page is loaded. Cheap (every 500 ms, no DOM work when state matches).
  setInterval(syncBanner, 500);
  syncBanner();
})();
''';

  void _pushWiktCollectMode(WebViewController c) {
    final on = _wiktCollectMode.value;
    try {
      c.runJavaScript('window.__cupWiktCollectActive = $on;');
    } catch (_) {}
  }

  void _handleWiktCollectMessage(String word) {
    final cleaned = word.trim();
    if (cleaned.isEmpty) return;
    final list = List<String>.from(_wiktCollectedWords.value);
    // Append even if duplicate — the user can dedup in the review dialog.
    // (Most language-study notes want each occurrence recorded.)
    list.add(cleaned);
    _wiktCollectedWords.value = list;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('wiktCollectedWords', list);
    });
    // Mirror the running list onto the system clipboard after every capture
    // so the user can paste the latest accumulated list anywhere without
    // opening the review dialog first. Pipe-separated to match the review
    // dialog's "Copy" button format (`words.join('|')`).
    Clipboard.setData(ClipboardData(text: list.join('|')));
  }

  void _persistWiktCollectedWords() {
    final snapshot = List<String>.from(_wiktCollectedWords.value);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('wiktCollectedWords', snapshot);
    });
  }

  void _showWiktCollectedDialog(BuildContext rootCtx) {
    showDialog(
      context: rootCtx,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ValueListenableBuilder<List<String>>(
            valueListenable: _wiktCollectedWords,
            builder: (_, words, __) {
              final joined = words.join('|');
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Collected words (${words.length})',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  ),
                  // Joined-output preview (the actual thing the user wants to
                  // copy). Read-only TextField so they can also long-press to
                  // select a subset.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: TextEditingController(text: joined),
                      readOnly: true,
                      maxLines: 3,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        labelText: 'Joined output ( | separated )',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // The list itself — each word has a remove button.
                  Flexible(
                    child: words.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('No words collected yet. Turn on collect mode and tap words.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: words.length,
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: SizedBox(
                                width: 28,
                                child: Text('${i + 1}.', textAlign: TextAlign.right),
                              ),
                              title: Text(words[i]),
                              trailing: IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  final next = List<String>.from(words)..removeAt(i);
                                  _wiktCollectedWords.value = next;
                                  _persistWiktCollectedWords();
                                },
                              ),
                            ),
                          ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.delete_sweep, size: 18),
                          label: const Text('Clear all'),
                          onPressed: words.isEmpty
                              ? null
                              : () async {
                                  final confirm = await showDialog<bool>(
                                    context: ctx,
                                    builder: (c) => AlertDialog(
                                      content: Text('Clear all ${words.length} collected words?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    _wiktCollectedWords.value = <String>[];
                                    _persistWiktCollectedWords();
                                  }
                                },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Dedup'),
                          onPressed: words.isEmpty
                              ? null
                              : () {
                                  final seen = <String>{};
                                  final next = <String>[];
                                  for (final w in words) {
                                    if (seen.add(w)) next.add(w);
                                  }
                                  _wiktCollectedWords.value = next;
                                  _persistWiktCollectedWords();
                                },
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          onPressed: words.isEmpty
                              ? null
                              : () async {
                                  await Clipboard.setData(ClipboardData(text: joined));
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text('Copied ${words.length} words'), duration: const Duration(seconds: 1)),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _saveFilmotBlacklist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('filmotChannelBlacklist', _filmotChannelBlacklist.toList());
  }

  Future<void> _saveSavedVideos() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('savedVideos', jsonEncode(_savedVideos));
  }

  /// Pushes the current blacklist + disabled state + known channel map into
  /// the dialog WebView and re-runs the annotator. Safe to call before the
  /// page has finished loading.
  void _pushFilmotConfig(WebViewController controller) {
    final list = jsonEncode(_filmotChannelBlacklist.toList());
    final disabled = _filmotBlacklistDisabled ? 'true' : 'false';
    final map = jsonEncode(_videoChannelCache);
    controller.runJavaScript(
      'window.__cupitorFilmotBlacklist = $list;'
      'window.__cupitorFilmotBlacklistDisabled = $disabled;'
      'window.__cupitorVideoChannel = Object.assign(window.__cupitorVideoChannel||{}, $map);'
      'if (window.__cupitorFilmotApply) window.__cupitorFilmotApply();'
    );
  }

  Future<void> _saveVideoChannelCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('videoChannelCache', jsonEncode(_videoChannelCache));
  }

  /// Resolves channel names for the given YouTube video IDs by calling the
  /// public oEmbed endpoint (no auth, returns `author_name`). Caches results
  /// in memory + SharedPreferences and pushes the resolved map back into all
  /// open filmot dialogs so their annotators can hide blacklisted rows.
  Future<void> _resolveVideoChannels(List<String> ids) async {
    final pending = ids
        .toSet()
        .where((id) => id.isNotEmpty
            && !_videoChannelCache.containsKey(id)
            && !_videoChannelInflight.contains(id))
        .toList();
    if (pending.isEmpty) return;
    _videoChannelInflight.addAll(pending);
    bool anyResolved = false;
    // Run up to 6 lookups in parallel; chunk through the list.
    const concurrency = 6;
    for (var i = 0; i < pending.length; i += concurrency) {
      final batch = pending.skip(i).take(concurrency).toList();
      await Future.wait(batch.map((id) async {
        try {
          final r = await http
              .get(Uri.parse('https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$id&format=json'))
              .timeout(const Duration(seconds: 8));
          if (r.statusCode == 200) {
            final j = jsonDecode(r.body) as Map<String, dynamic>;
            final author = (j['author_name'] ?? '').toString().trim();
            if (author.isNotEmpty) {
              _videoChannelCache[id] = author;
              anyResolved = true;
            } else {
              _videoChannelCache[id] = ''; // negative cache to avoid retries
            }
          } else if (r.statusCode == 401 || r.statusCode == 404) {
            _videoChannelCache[id] = '';
          }
        } catch (_) { /* leave uncached so we retry later */ }
        _videoChannelInflight.remove(id);
      }));
      // Push partial results so the UI updates progressively.
      if (anyResolved) {
        for (final entry in _dialog2Controllers.entries) {
          if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
        }
      }
    }
    if (anyResolved) await _saveVideoChannelCache();
  }

  /// Injects the Filmot annotator into the dialog WebView. Idempotent — the
  /// script self-guards against re-installation. Handles both layouts:
  /// (a) search results — `<div id="vcard_{ytId}">` blocks with NO channel info
  ///     in the HTML, resolved via Flutter-side oEmbed lookups;
  /// (b) sidebyside detail — a single `a[href*="/channel/"]` whose text is
  ///     the icon, so we read the channel name from the resolved map keyed by
  ///     the video id in the URL.
  void _injectFilmotHelper(WebViewController controller) {
    final list = jsonEncode(_filmotChannelBlacklist.toList());
    final disabled = _filmotBlacklistDisabled ? 'true' : 'false';
    final map = jsonEncode(_videoChannelCache);
    controller.runJavaScript('''
      window.__cupitorFilmotBlacklist = $list;
      window.__cupitorFilmotBlacklistDisabled = $disabled;
      window.__cupitorVideoChannel = Object.assign(window.__cupitorVideoChannel||{}, $map);
      (function(){
        if (window.__cupitorFilmotInstalled) { if (window.__cupitorFilmotApply) window.__cupitorFilmotApply(); return; }
        window.__cupitorFilmotInstalled = true;
        function bridge(msg) { try { FilmotBridge.postMessage(JSON.stringify(msg)); } catch(e) {} }
        function titleFromCard(card) {
          var a = card.querySelector('a[id^="vlink"]');
          if (a) return (a.textContent || '').trim().slice(0, 200);
          var t = card.querySelector('h1,h2,h3,h4,h5,.title,[class*=title]');
          if (t) return (t.textContent || '').trim().slice(0, 200);
          return '';
        }
        // Set a value only if it differs from current, to skip layout thrashing
        // when annotate runs repeatedly with the same data.
        function setStyle(el, prop, val) { if (el.style[prop] !== val) el.style[prop] = val; }
        function setText(el, val) { if (el.textContent !== val) el.textContent = val; }

        // Auto-skip the currently-playing video if its channel is blacklisted.
        // Filmot's prev/next buttons swap the iframe src in place — so the
        // only reliable hook is to watch the iframe and invoke filmot's own
        // navigateToLocalResult/nextVideo. Throttled to keep the skip from
        // racing when several blocked channels are queued in a row.
        var lastAutoSkipAt = 0;
        var lastCheckedSrc = '';
        function blacklistedChannelOf(videoId) {
          if (!videoId) return null;
          var disabled = window.__cupitorFilmotBlacklistDisabled === true;
          if (disabled) return null;
          var bl = window.__cupitorFilmotBlacklist || [];
          if (!bl.length) return null;
          var ch = (window.__cupitorVideoChannel || {})[videoId];
          if (!ch) return null;
          for (var i = 0; i < bl.length; i++) if (bl[i] === ch) return ch;
          return null;
        }
        function currentVideoId() {
          var ifr = document.getElementById('player');
          if (ifr && ifr.src) {
            var m = ifr.src.match(/youtube\\.com\\/embed\\/([A-Za-z0-9_-]{6,})/);
            if (m) return m[1];
          }
          // Fallback to filmot's own global if it's defined.
          if (typeof window.currentVideoID === 'string' && window.currentVideoID) return window.currentVideoID;
          return null;
        }
        // Find the index of the currently-playing video in filmot's local
        // vcard list (`<div class="vcardN ...">`). Needed by playNextVideo().
        function currentVcardIndex() {
          var id = currentVideoId();
          if (!id) return -1;
          var card = document.getElementById('vcard_' + id);
          if (!card) return -1;
          var m = (card.className || '').match(/(?:^|\\s)vcard(\\d+)(?:\\s|\$)/);
          return m ? parseInt(m[1], 10) : -1;
        }
        function autoSkipIfBlacklisted(reason) {
          var id = currentVideoId();
          if (!id) return;
          var ch = (window.__cupitorVideoChannel || {})[id];
          if (ch === undefined) {
            // Not resolved yet — ask Flutter to resolve so a later push can re-check.
            bridge({action:'resolveVideos', ids:[id]});
            return;
          }
          var blocked = blacklistedChannelOf(id);
          if (!blocked) return;
          var now = Date.now();
          if (now - lastAutoSkipAt < 800) return;
          lastAutoSkipAt = now;
          try { if (typeof window.stopDownTimer === 'function') window.stopDownTimer(); } catch(e){}
          // Preferred path: filmot's own next button carries the correct
          // current index in its onclick, and uses playNextVideo() which
          // already skips past `.d-none` cards.
          try {
            var btn = document.getElementById('nextVideoButton');
            if (btn && !btn.classList.contains('d-none')) { btn.click(); return; }
          } catch(e){}
          // Fallback: derive the current index from the highlighted vcard
          // and invoke playNextVideo directly.
          try {
            var idx = currentVcardIndex();
            if (idx >= 0 && typeof window.playNextVideo === 'function') { window.playNextVideo(idx, 1); return; }
          } catch(e){}
          // Last-ditch fallbacks.
          try {
            if (typeof window.nextVideo === 'function') { window.nextVideo(); return; }
            if (typeof window.navigateToLocalResult === 'function') window.navigateToLocalResult(1);
          } catch(e){}
        }

        function annotate() {
          var bl = window.__cupitorFilmotBlacklist || [];
          var disabled = window.__cupitorFilmotBlacklistDisabled === true;
          var map = window.__cupitorVideoChannel || {};
          var blSet = {};
          for (var i = 0; i < bl.length; i++) blSet[bl[i]] = true;

          // --- (a) Search-result cards ---
          var cards = document.querySelectorAll('[id^="vcard_"]');
          var seenChannels = {};
          var unknownIds = [];
          for (var c = 0; c < cards.length; c++) {
            var card = cards[c];
            var id = card.id.replace(/^vcard_/, '');
            if (!id) continue;
            var ch = map[id];
            if (ch === undefined) {
              unknownIds.push(id);
              setStyle(card, 'opacity', '0.6');
            } else {
              setStyle(card, 'opacity', '');
              if (ch) seenChannels[ch] = true;
              // Use Bootstrap's `d-none` instead of inline style so filmot's
              // own playNextVideo()/playNextVideo prev path treats blacklisted
              // cards as "skipped" — they call `card.classList.contains("d-none")`.
              if (!disabled && ch && blSet[ch]) {
                if (!card.classList.contains('d-none')) card.classList.add('d-none');
              } else {
                if (card.classList.contains('d-none')) card.classList.remove('d-none');
              }
            }
            // Annotate once; label refreshed only when its text actually changes.
            if (card.getAttribute('data-cup-ann') !== '1') {
              card.setAttribute('data-cup-ann', '1');
              var bar = document.createElement('div');
              bar.className = '__cup_bar';
              bar.style.cssText = 'display:flex;gap:4px;padding:2px 0;font-size:11px';
              var label = document.createElement('span');
              label.className = '__cup_channel_label';
              label.style.cssText = 'flex:1;color:#555;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
              bar.appendChild(label);
              var bbtn = document.createElement('button');
              bbtn.textContent = '🚫';
              bbtn.title = 'Blacklist this channel';
              bbtn.style.cssText = 'padding:1px 6px;font-size:11px;border:1px solid #888;background:#fee;cursor:pointer;border-radius:3px;line-height:1';
              bbtn.onclick = (function(videoId, lbl){ return function(e){
                e.preventDefault(); e.stopPropagation();
                var channel = (window.__cupitorVideoChannel || {})[videoId];
                if (!channel) { setText(lbl, '(no channel resolved yet)'); return; }
                bridge({action:'blockChannel', channel: channel});
              }; })(id, label);
              bar.appendChild(bbtn);
              var sbtn = document.createElement('button');
              sbtn.textContent = '💾';
              sbtn.title = 'Save video URL';
              sbtn.style.cssText = 'padding:1px 6px;font-size:11px;border:1px solid #888;background:#efe;cursor:pointer;border-radius:3px;line-height:1';
              sbtn.onclick = (function(videoId, btn, cardEl){ return function(e){
                e.preventDefault(); e.stopPropagation();
                var channel = (window.__cupitorVideoChannel || {})[videoId] || '';
                bridge({action:'saveVideo', url:'https://www.youtube.com/watch?v=' + videoId, channel: channel, title: titleFromCard(cardEl)});
                btn.textContent = '✅';
              }; })(id, sbtn, card);
              bar.appendChild(sbtn);
              card.insertBefore(bar, card.firstChild);
            }
            var existingLabel = card.querySelector('.__cup_channel_label');
            if (existingLabel) {
              var lblText = (ch === undefined) ? '(resolving channel…)' : (ch === '' ? '(channel unknown)' : ch);
              setText(existingLabel, lblText);
            }
          }

          // --- (b) Detail-page channel link (no anchor text — read from URL) ---
          var detailLinks = document.querySelectorAll('a[href*="/channel/"], a[href*="youtube.com/@"]');
          var detailId = null;
          var pm = location.pathname.match(/\\/sidebyside\\/([A-Za-z0-9_-]{6,})/);
          if (pm) detailId = pm[1];
          for (var d = 0; d < detailLinks.length; d++) {
            var dl = detailLinks[d];
            if (dl.getAttribute('data-cup-ann') === '1') continue;
            dl.setAttribute('data-cup-ann', '1');
            var lbl2 = document.createElement('span');
            lbl2.className = '__cup_channel_label';
            lbl2.style.cssText = 'margin:0 6px;font-size:12px;color:#444';
            var ch2 = (detailId && map[detailId]) ? map[detailId] : '';
            lbl2.textContent = ch2 || '(resolving channel…)';
            if (ch2) seenChannels[ch2] = true;
            dl.parentNode.insertBefore(lbl2, dl);
            var b2 = document.createElement('button');
            b2.className = '__cup_btn';
            b2.textContent = '🚫';
            b2.title = 'Blacklist this channel';
            b2.style.cssText = 'margin:0 4px;padding:1px 6px;font-size:11px;border:1px solid #888;background:#fee;cursor:pointer;border-radius:3px;line-height:1';
            b2.onclick = (function(vId, lbl){ return function(e){
              e.preventDefault(); e.stopPropagation();
              var ch = vId ? (window.__cupitorVideoChannel || {})[vId] : '';
              if (!ch) { setText(lbl, '(no channel resolved yet)'); return; }
              bridge({action:'blockChannel', channel: ch});
            }; })(detailId, lbl2);
            dl.parentNode.insertBefore(b2, dl.nextSibling);
            if (detailId) {
              unknownIds.push(detailId);
              var s2 = document.createElement('button');
              s2.className = '__cup_btn';
              s2.textContent = '💾';
              s2.title = 'Save video URL';
              s2.style.cssText = 'margin:0 4px;padding:1px 6px;font-size:11px;border:1px solid #888;background:#efe;cursor:pointer;border-radius:3px;line-height:1';
              s2.onclick = (function(vId, btn){ return function(e){
                e.preventDefault(); e.stopPropagation();
                var ch = (window.__cupitorVideoChannel || {})[vId] || '';
                var ttl = document.title || '';
                bridge({action:'saveVideo', url:'https://www.youtube.com/watch?v=' + vId, channel: ch, title: ttl});
                btn.textContent = '✅';
              }; })(detailId, s2);
              dl.parentNode.insertBefore(s2, b2.nextSibling);
            }
          }

          // --- (c) Currently-playing video bar ---
          // Insert a block+save bar above the player. Filmot wraps #player
          // (an iframe) in #playerTop, which uses Bootstrap's
          // embed-responsive-16by9 — that gives the iframe `position:absolute`
          // inside its parent, so inserting a sibling there makes the bar
          // invisible. We anchor on #playerTop instead (or fall back to
          // #playerparrent's first child) and insert in the normal flow.
          var playerEl = document.getElementById('player');
          if (playerEl) {
            var anchor = document.getElementById('playerTop') || playerEl.parentNode;
            var anchorParent = anchor && anchor.parentNode;
            var prev = anchor && anchor.previousElementSibling;
            var pBar = (prev && prev.classList && prev.classList.contains('__cup_player_bar')) ? prev : null;
            if (!pBar && anchorParent) {
              pBar = document.createElement('div');
              pBar.className = '__cup_player_bar';
              pBar.style.cssText = 'display:flex;gap:6px;align-items:center;padding:6px 8px;font-size:13px;background:#fffbe6;border:1px solid #e0c060;border-radius:4px;margin:6px 0';
              var pLabel = document.createElement('span');
              pLabel.className = '__cup_player_channel_label';
              pLabel.style.cssText = 'flex:1;color:#444;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
              pBar.appendChild(pLabel);
              var pBlock = document.createElement('button');
              pBlock.textContent = '🚫 Block channel';
              pBlock.title = 'Blacklist this channel';
              pBlock.style.cssText = 'padding:2px 8px;font-size:11px;border:1px solid #888;background:#fee;cursor:pointer;border-radius:3px;line-height:1.2';
              pBlock.onclick = function(e) {
                e.preventDefault(); e.stopPropagation();
                var vid = currentVideoId();
                var ch = vid ? (window.__cupitorVideoChannel || {})[vid] : '';
                if (!ch) { setText(pLabel, '(no channel resolved yet)'); return; }
                bridge({action:'blockChannel', channel: ch});
              };
              pBar.appendChild(pBlock);
              var pSave = document.createElement('button');
              pSave.textContent = '💾 Save';
              pSave.title = 'Save video URL';
              pSave.style.cssText = 'padding:2px 8px;font-size:11px;border:1px solid #888;background:#efe;cursor:pointer;border-radius:3px;line-height:1.2';
              pSave.onclick = function(e) {
                e.preventDefault(); e.stopPropagation();
                var vid = currentVideoId();
                if (!vid) return;
                var ch = (window.__cupitorVideoChannel || {})[vid] || '';
                bridge({action:'saveVideo', url:'https://www.youtube.com/watch?v=' + vid, channel: ch, title: document.title || ''});
                pSave.textContent = '✅ Saved';
                setTimeout(function(){ pSave.textContent = '💾 Save'; }, 1500);
              };
              pBar.appendChild(pSave);
              anchorParent.insertBefore(pBar, anchor);
            }
            // Refresh label / record channel-seen for the player's current video.
            var pVid = currentVideoId();
            var pLbl = pBar && pBar.querySelector('.__cup_player_channel_label');
            if (pLbl) {
              if (!pVid) {
                setText(pLbl, '(no video)');
              } else {
                var pCh = map[pVid];
                if (pCh === undefined) {
                  setText(pLbl, '(resolving channel…)');
                  unknownIds.push(pVid);
                } else if (pCh === '') {
                  setText(pLbl, '(channel unknown)');
                } else {
                  setText(pLbl, pCh);
                  seenChannels[pCh] = true;
                }
              }
            }
          }

          // Keep already-annotated detail-page labels in sync with the map.
          var dLabels = document.querySelectorAll('a[data-cup-ann="1"]');
          for (var dl2 = 0; dl2 < dLabels.length; dl2++) {
            var prev = dLabels[dl2].previousSibling;
            if (prev && prev.classList && prev.classList.contains('__cup_channel_label')) {
              var dch = (detailId && map[detailId]) ? map[detailId] : '';
              var dtxt = dch || ((detailId && map[detailId] === '') ? '(channel unknown)' : '(resolving channel…)');
              setText(prev, dtxt);
              if (dch) seenChannels[dch] = true;
            }
          }

          // Report known channels to Flutter so the dialog UI can list them.
          var seenArr = []; for (var k in seenChannels) seenArr.push(k);
          bridge({action:'channelsSeen', channels: seenArr});
          if (unknownIds.length) {
            var dedup = {}; var uniq = [];
            for (var u = 0; u < unknownIds.length; u++) { if (!dedup[unknownIds[u]]) { dedup[unknownIds[u]] = 1; uniq.push(unknownIds[u]); } }
            bridge({action:'resolveVideos', ids: uniq});
          }
          // If the currently-playing video became blacklisted (new entry, or
          // its channel just resolved), skip to the next one.
          autoSkipIfBlacklisted('annotate');
        }

        // Debounced scheduler — protects the main thread from filmot's
        // own constant DOM updates (subtitle highlights, time ticks, etc.).
        var annotateTimer = null;
        function scheduleAnnotate() {
          if (annotateTimer) return;
          annotateTimer = setTimeout(function(){
            annotateTimer = null;
            try { annotate(); } catch(e) {}
          }, 400);
        }
        window.__cupitorFilmotApply = scheduleAnnotate;

        // Only run annotate when DOM mutations actually involve a vcard or a
        // channel link — ignore subtitle, badge, and player tick updates.
        function relevant(mutations) {
          for (var mi = 0; mi < mutations.length; mi++) {
            var mu = mutations[mi];
            if (mu.type !== 'childList') continue;
            for (var ai = 0; ai < mu.addedNodes.length; ai++) {
              var an = mu.addedNodes[ai];
              if (!an || an.nodeType !== 1) continue;
              if (an.id && an.id.indexOf('vcard_') === 0) return true;
              if (an.id === 'player') return true;
              // Skip the bars we insert ourselves
              if (an.className === '__cup_bar' || an.className === '__cup_player_bar' || an.className === '__cup_channel_label') continue;
              if (an.querySelector && (an.querySelector('[id^="vcard_"]') || an.querySelector('#player') || an.querySelector('a[href*="/channel/"]') || an.querySelector('a[href*="youtube.com/@"]'))) return true;
            }
            for (var ri = 0; ri < mu.removedNodes.length; ri++) {
              var rn = mu.removedNodes[ri];
              if (!rn || rn.nodeType !== 1) continue;
              if (rn.id && rn.id.indexOf('vcard_') === 0) return true;
            }
          }
          return false;
        }

        annotate();
        var mo = new MutationObserver(function(mutations){
          try { if (relevant(mutations)) scheduleAnnotate(); } catch(e) {}
        });
        mo.observe(document.body || document.documentElement, {childList:true, subtree:true});

        // Watch the player iframe — filmot's Next/Prev buttons swap its src
        // without navigating, so this is the only reliable signal that the
        // currently-playing video has changed.
        function attachIframeWatcher() {
          var ifr = document.getElementById('player');
          if (!ifr || ifr.__cupWatched) return;
          ifr.__cupWatched = true;
          // Annotate now that the iframe is in the DOM — this is what makes
          // the player-bar (block / save buttons) actually appear when the
          // iframe was added after the page's initial parse.
          scheduleAnnotate();
          var srcMo = new MutationObserver(function(){
            if (ifr.src === lastCheckedSrc) return;
            lastCheckedSrc = ifr.src;
            autoSkipIfBlacklisted('iframe-src');
            // Refresh the player-bar channel label for the new video.
            scheduleAnnotate();
          });
          srcMo.observe(ifr, {attributes:true, attributeFilter:['src']});
          lastCheckedSrc = ifr.src || '';
          // Also fire once now in case the initial video is already blocked.
          autoSkipIfBlacklisted('initial');
        }
        attachIframeWatcher();
        // The iframe may not exist yet when we install — keep trying briefly.
        var watcherTries = 0;
        var watcherTimer = setInterval(function(){
          watcherTries++;
          attachIframeWatcher();
          var ifr2 = document.getElementById('player');
          if ((ifr2 && ifr2.__cupWatched) || watcherTries > 20) clearInterval(watcherTimer);
        }, 300);
      })();
    ''');
  }

  void _handleFilmotMessage(String dialogId, String message) {
    Map<String, dynamic> msg;
    try { msg = jsonDecode(message) as Map<String, dynamic>; } catch (_) { return; }
    final action = msg['action']?.toString();
    if (action == 'channelsSeen') {
      final list = (msg['channels'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
      _filmotChannelsSeen[dialogId] = list;
    } else if (action == 'resolveVideos') {
      final ids = (msg['ids'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
      if (ids.isNotEmpty) {
        // Fire-and-forget; _resolveVideoChannels pushes results back via JS.
        _resolveVideoChannels(ids);
      }
    } else if (action == 'blockChannel') {
      final channel = msg['channel']?.toString() ?? '';
      if (channel.isEmpty) return;
      _filmotChannelBlacklist.add(channel);
      _saveFilmotBlacklist();
      // Push updated config back to every active filmot dialog so all open
      // dialogs immediately hide rows from this channel.
      for (final entry in _dialog2Controllers.entries) {
        if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
      }
      _showDialog2SnackBar(dialogId, 'Blacklisted: $channel');
    } else if (action == 'saveVideo') {
      final url = msg['url']?.toString() ?? '';
      if (url.isEmpty) {
        _showDialog2SnackBar(dialogId, 'Could not detect a video URL on this page');
        return;
      }
      final title = msg['title']?.toString() ?? '';
      if (_savedVideos.any((e) => e['url'] == url)) {
        _showDialog2SnackBar(dialogId, 'Already saved: ${title.isNotEmpty ? title : url}');
        return;
      }
      _savedVideos.add({
        'url': url,
        'channel': msg['channel']?.toString() ?? '',
        'title': title,
        'savedAt': DateTime.now().toIso8601String(),
      });
      _saveSavedVideos();
      _showDialog2SnackBar(dialogId,
          'Saved: ${title.isNotEmpty ? title : url} (${_savedVideos.length} total)');
    }
  }

  void _showFilmotChannelsDialog(BuildContext ctx, String dialogId, WebViewController controller) {
    final seen = (_filmotChannelsSeen[dialogId] ?? <String>{}).toList()..sort();
    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) {
          // Union of "seen on this page" plus everything already blacklisted, so
          // users can edit entries even when the relevant row isn't on screen.
          final all = <String>{...seen, ..._filmotChannelBlacklist}.toList()..sort();
          return AlertDialog(
            title: Row(
              children: [
                Expanded(child: Text('Channel blacklist')),
                Tooltip(
                  message: 'Temporarily ignore the blacklist for this session — useful when too few matches show up.',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Disable', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _filmotBlacklistDisabled,
                        onChanged: (v) {
                          setState(() => _filmotBlacklistDisabled = v);
                          setStateDialog(() {});
                          for (final entry in _dialog2Controllers.entries) {
                            if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: all.isEmpty
                  ? Text('No channels seen yet on this page.')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: all.length,
                      itemBuilder: (_, i) {
                        final name = all[i];
                        final blocked = _filmotChannelBlacklist.contains(name);
                        return CheckboxListTile(
                          dense: true,
                          title: Text(name, overflow: TextOverflow.ellipsis),
                          value: blocked,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _filmotChannelBlacklist.add(name);
                              } else {
                                _filmotChannelBlacklist.remove(name);
                              }
                            });
                            _saveFilmotBlacklist();
                            setStateDialog(() {});
                            for (final entry in _dialog2Controllers.entries) {
                              if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
                            }
                          },
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() => _filmotChannelBlacklist.clear());
                  _saveFilmotBlacklist();
                  setStateDialog(() {});
                  for (final entry in _dialog2Controllers.entries) {
                    if (_isFilmotUrl(_dialog2Urls[entry.key])) _pushFilmotConfig(entry.value);
                  }
                },
                child: Text('Clear all'),
              ),
              TextButton(onPressed: () => Navigator.of(dctx).pop(), child: Text('Done')),
            ],
          );
        },
      ),
    );
  }

  /// Asks the dialog WebView for the YouTube URL of the focused result on the
  /// current Filmot page, then saves it. "Focused" = the row currently nearest
  /// the viewport center, which works for both the search-results layout (many
  /// rows) and the single-video layout (one row).
  // Long-lived translator pool keyed by "src-tgt" so the snippet bridge
  // doesn't pay the open/close + model-check cost per cue. Closed in dispose.
  final Map<String, mlkit.OnDeviceTranslator> _translatorPool = {};

  Future<mlkit.OnDeviceTranslator?> _getOrOpenTranslator(String src, String tgt) async {
    final key = '$src-$tgt';
    final cached = _translatorPool[key];
    if (cached != null) return cached;
    final sl = _toMlKitLang(src);
    final tl = _toMlKitLang(tgt);
    if (sl == null || tl == null) return null;
    final mm = mlkit.OnDeviceTranslatorModelManager();
    if (!await mm.isModelDownloaded(sl.bcpCode)) await mm.downloadModel(sl.bcpCode);
    if (!await mm.isModelDownloaded(tl.bcpCode)) await mm.downloadModel(tl.bcpCode);
    final t = mlkit.OnDeviceTranslator(sourceLanguage: sl, targetLanguage: tl);
    _translatorPool[key] = t;
    return t;
  }

  /// Page → Dart translation bridge for snippet.js. Payload:
  ///   { id: <int>, text: <string>, source: <ISO>, target: <ISO> }
  /// Tries the Google translate endpoint first (sentence-level quality,
  /// works without per-language model downloads). On network / HTTP error,
  /// falls back to on-device ML Kit (offline, slower first-use because of
  /// the ~30 MB per-language model download). Result is delivered to the
  /// page via window.__cupTranslated(id, result).
  Future<void> _handleTranslateRequest(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; } catch (_) { return; }
    final id = req['id'];
    final text = (req['text'] as String? ?? '').trim();
    final src = (req['source'] as String? ?? 'sv').trim();
    final tgt = (req['target'] as String? ?? 'en').trim();
    if (id == null || text.isEmpty) return;
    // Opt-in, per request: a caller that doesn't ask gets exactly the reply it
    // has always got, down to the argument count. That is what keeps the four
    // existing call sites — playlist phrases, subtitle lines, the corresponding
    // -words heading and its back-translation check — out of the blast radius.
    final wantsDetail = req['detail'] == true;

    String? result;
    Map<String, dynamic>? detail;
    String? errMsg;
    // Path 1: Google translate API (free, public).
    try {
      if (wantsDetail) {
        final d = await _translateDetailed(text, src, tgt);
        // An empty primary means the response held nothing usable. Fall
        // through to ML Kit rather than hand the page a blank translation
        // dressed up as a success.
        if (d.primary.isEmpty) throw 'empty result';
        result = d.primary;
        detail = d.toJson(provider: 'google');
      } else {
        result = await _translateText(text, src, tgt);
      }
    } catch (e) {
      errMsg = 'api: $e';
    }
    // Path 2: ML Kit fallback (on-device).
    if (result == null) {
      try {
        final tr = await _getOrOpenTranslator(src, tgt);
        if (tr != null) {
          result = await tr.translateText(text);
          // No dictionary exists on-device. Say so via `provider` — otherwise
          // "no senses" is indistinguishable from "this word has one sense",
          // and the page would state the second while meaning the first.
          if (wantsDetail) {
            detail = const TranslateDetail.empty().toJson(provider: 'mlkit');
          }
        }
        else errMsg = (errMsg ?? '') + '; mlkit: language unsupported';
      } catch (e) {
        errMsg = (errMsg ?? '') + '; mlkit: $e';
      }
    }
    // Positional args are (id, result, err, detail). The detail argument is
    // appended ONLY for a caller that asked, so an untouched call site keeps
    // receiving the same two-argument invocation it always did.
    final js = result != null
        ? (wantsDetail
            ? 'window.__cupTranslated && window.__cupTranslated($id, ${jsonEncode(result)}, null, ${jsonEncode(detail)});'
            : 'window.__cupTranslated && window.__cupTranslated($id, ${jsonEncode(result)});')
        : 'window.__cupTranslated && window.__cupTranslated($id, null, ${jsonEncode(errMsg ?? 'translate failed')});';
    // TranslateRequest is registered on BOTH controllers (main _controller for
    // snippet.js, dialogController for the study app), and a JavaScriptMessage
    // doesn't say which one sent it. Deliver the reply to both — the guard plus
    // each page's own pending-id map makes it a no-op on the page that didn't
    // originate the request. Without this, a request from the dialog webview
    // (the study page's 🌐 translate) got its reply run in the main webview and
    // never arrived → translate-timeout.
    try { _controller.runJavaScript(js); } catch (_) {}
    try { dialogController?.runJavaScript(js); } catch (_) {}
  }

  // Maps our ISO-639-1 codes to ML Kit's TranslateLanguage enum. Returns null
  // if the language isn't supported on-device.
  mlkit.TranslateLanguage? _toMlKitLang(String code) {
    switch (code.toLowerCase()) {
      case 'sv': return mlkit.TranslateLanguage.swedish;
      case 'es': return mlkit.TranslateLanguage.spanish;
      case 'en': return mlkit.TranslateLanguage.english;
      case 'de': return mlkit.TranslateLanguage.german;
      case 'fr': return mlkit.TranslateLanguage.french;
      case 'it': return mlkit.TranslateLanguage.italian;
      case 'pt': return mlkit.TranslateLanguage.portuguese;
      case 'nl': return mlkit.TranslateLanguage.dutch;
      case 'no': return mlkit.TranslateLanguage.norwegian;
      case 'da': return mlkit.TranslateLanguage.danish;
      case 'fi': return mlkit.TranslateLanguage.finnish;
      case 'pl': return mlkit.TranslateLanguage.polish;
      case 'ru': return mlkit.TranslateLanguage.russian;
      case 'ja': return mlkit.TranslateLanguage.japanese;
      case 'zh': return mlkit.TranslateLanguage.chinese;
      case 'ko': return mlkit.TranslateLanguage.korean;
      case 'ar': return mlkit.TranslateLanguage.arabic;
      case 'hi': return mlkit.TranslateLanguage.hindi;
      case 'tr': return mlkit.TranslateLanguage.turkish;
      default: return null;
    }
  }

  /// Translates `text` using Android/iOS ML Kit on-device. Downloads the
  /// required language models on first use (one-time, ~30MB per language).
  /// Works offline once the models are present.
  Future<String> _translateOnDevice(String text, String sourceLang, String targetLang) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw 'On-device translation requires Android or iOS';
    }
    final sl = _toMlKitLang(sourceLang);
    final tl = _toMlKitLang(targetLang);
    if (sl == null || tl == null) {
      throw 'Unsupported language for ML Kit: $sourceLang→$targetLang';
    }
    final mm = mlkit.OnDeviceTranslatorModelManager();
    if (!await mm.isModelDownloaded(sl.bcpCode)) {
      await mm.downloadModel(sl.bcpCode);
    }
    if (!await mm.isModelDownloaded(tl.bcpCode)) {
      await mm.downloadModel(tl.bcpCode);
    }
    final translator = mlkit.OnDeviceTranslator(sourceLanguage: sl, targetLanguage: tl);
    try {
      return await translator.translateText(text);
    } finally {
      await translator.close();
    }
  }

  /// Translates a list of lines into the target language, preserving the list
  /// order and length. Uses Google if `preferOnDevice` is false (auto-falls
  /// back to on-device on failure); uses ML Kit directly when true. Empty
  /// input lines come back as empty strings.
  Future<List<String>> _translateLines(
    List<String> lines,
    String sourceLang,
    String targetLang, {
    required bool preferOnDevice,
  }) async {
    final out = List<String>.filled(lines.length, '');
    if (lines.isEmpty) return out;
    if (preferOnDevice) {
      // Open one translator and reuse it for the whole batch.
      final sl = _toMlKitLang(sourceLang);
      final tl = _toMlKitLang(targetLang);
      if (sl == null || tl == null) throw 'Unsupported language for ML Kit: $sourceLang→$targetLang';
      final mm = mlkit.OnDeviceTranslatorModelManager();
      if (!await mm.isModelDownloaded(sl.bcpCode)) await mm.downloadModel(sl.bcpCode);
      if (!await mm.isModelDownloaded(tl.bcpCode)) await mm.downloadModel(tl.bcpCode);
      final translator = mlkit.OnDeviceTranslator(sourceLanguage: sl, targetLanguage: tl);
      try {
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trim().isEmpty) continue;
          out[i] = await translator.translateText(lines[i]);
        }
        return out;
      } finally {
        await translator.close();
      }
    }
    // Google path — N parallel HTTP calls in batches of 6. On any individual
    // failure, fall back to on-device for that line (and the rest).
    const concurrency = 6;
    Object? googleErr;
    for (var i = 0; i < lines.length; i += concurrency) {
      final end = (i + concurrency < lines.length) ? i + concurrency : lines.length;
      final futures = <Future<void>>[];
      for (var j = i; j < end; j++) {
        final idx = j;
        if (lines[idx].trim().isEmpty) continue;
        futures.add(() async {
          try {
            out[idx] = await _translateText(lines[idx], sourceLang, targetLang);
          } catch (e) {
            googleErr = e;
          }
        }());
      }
      await Future.wait(futures);
      if (googleErr != null) break;
    }
    if (googleErr != null) {
      // One or more failed via Google — finish the rest on-device.
      final pending = <int>[];
      for (var k = 0; k < lines.length; k++) {
        if (out[k].isEmpty && lines[k].trim().isNotEmpty) pending.add(k);
      }
      if (pending.isNotEmpty) {
        final fallback = await _translateLines(
          pending.map((i) => lines[i]).toList(),
          sourceLang, targetLang,
          preferOnDevice: true,
        );
        for (var k = 0; k < pending.length; k++) {
          out[pending[k]] = fallback[k];
        }
      }
    }
    return out;
  }

  /// Translates `text` via Google's public unauthenticated endpoint. Returns
  /// the translation as a single string (segments rejoined). Throws on error.
  Future<String> _translateText(String text, String sourceLang, String targetLang) async {
    final uri = Uri.parse(
      'https://translate.googleapis.com/translate_a/single'
      '?client=gtx&sl=$sourceLang&tl=$targetLang&dt=t'
      '&q=${Uri.encodeQueryComponent(text)}'
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw 'HTTP ${resp.statusCode}';
    }
    final body = jsonDecode(resp.body) as List;
    final segments = body[0] as List;
    final out = StringBuffer();
    for (final seg in segments) {
      if (seg is List && seg.isNotEmpty && seg[0] != null) {
        out.write(seg[0].toString());
      }
    }
    return out.toString();
  }

  /// Same endpoint and same single request as [_translateText], asking also for
  /// the dictionary (`dt=bd`) and alternate-translation (`dt=at`) blocks — the
  /// per-sense data a word lookup needs, which the plain call throws away.
  ///
  /// Deliberately NOT merged into [_translateText]: the subtitle and batch
  /// paths translate whole sentences, which carry no dictionary entry, so they
  /// keep the lean request and are unaffected by any of this.
  Future<TranslateDetail> _translateDetailed(
      String text, String sourceLang, String targetLang) async {
    final uri = Uri.parse(
      'https://translate.googleapis.com/translate_a/single'
      '?client=gtx&sl=$sourceLang&tl=$targetLang&dt=t&dt=bd&dt=at'
      '&q=${Uri.encodeQueryComponent(text)}'
    );
    final resp = await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw 'HTTP ${resp.statusCode}';
    }
    return parseTranslateResponse(jsonDecode(resp.body));
  }

  // ---------- YouTube subtitle download ----------

  /// Pulls a YouTube video id out of any of the URL forms we support
  /// (`/watch?v=…`, `/shorts/…`, `/embed/…`, `/live/…`, `youtu.be/…`). Returns
  /// null if the input doesn't look like a YouTube URL/id at all.
  String? _extractYouTubeVideoId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    // Bare 11-char id (what users sometimes paste from the share menu).
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(trimmed)) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(seg)) return seg;
    }
    if (host.endsWith('youtube.com') || host.endsWith('youtube-nocookie.com')) {
      final v = uri.queryParameters['v'];
      if (v != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(v)) return v;
      // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
      for (final pat in const ['shorts', 'embed', 'live', 'v']) {
        final idx = uri.pathSegments.indexOf(pat);
        if (idx >= 0 && idx + 1 < uri.pathSegments.length) {
          final cand = uri.pathSegments[idx + 1];
          if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(cand)) return cand;
        }
      }
    }
    return null;
  }

  // ---------- YouTube subtitle download ----------

  /// Lists available caption tracks via `youtubedl-android` (Android) or a
  /// `yt-dlp` subprocess (macOS). yt-dlp handles the PO-token wall on its
  /// side, so we don't see the 0-byte responses we got from every in-app
  /// HTTP/WebView attempt.
  Future<Map<String, dynamic>> _fetchYouTubeCaptionTracks(String videoId) async {
    if (!await YtDlpService.isAvailable()) {
      throw YtDlpService.installHint();
    }
    final result = await YtDlpService.listTracks(
      'https://www.youtube.com/watch?v=$videoId',
    );
    return {
      'title': result.title,
      'tracks': result.tracks.map((t) => t.toMap()).toList(),
    };
  }

  /// Downloads the chosen caption track via yt-dlp and parses it.
  /// `baseUrl` is unused (only kept for signature compatibility with the
  /// old WebView path); yt-dlp constructs whatever URL it needs internally.
  Future<List<Map<String, dynamic>>> _fetchCaptionsJson3({
    required String baseUrl,
    required String videoId,
    required String languageCode,
    required String kind,
  }) async {
    final sub = await YtDlpService.downloadSubtitle(
      videoUrl: 'https://www.youtube.com/watch?v=$videoId',
      languageCode: languageCode,
      kind: kind,
    );
    if (sub.body.isEmpty) {
      throw 'yt-dlp returned an empty body for $languageCode'
          '${kind == 'asr' ? ' (auto)' : ''}';
    }
    final List<Map<String, dynamic>> lines = switch (sub.format) {
      'json3' => await compute(_parseYtJson3Captions, sub.body),
      'vtt'   => await compute(_parseVttCaptions, sub.body),
      _       => await compute(_parseYtJson3Captions, sub.body),
    };
    if (lines.isEmpty) {
      throw 'yt-dlp returned ${sub.body.length}B (${sub.format}) but parsed 0 lines';
    }
    return lines;
  }

  /// Picks the default caption track to highlight in the picker. Preference
  /// order: manual track for current `_selectedLanguage` → any manual track
  /// → auto-generated track for current `_selectedLanguage` → first track.
  int _defaultCaptionTrackIndex(List<Map<String, dynamic>> tracks) {
    bool isManual(Map<String, dynamic> t) => (t['kind'] as String? ?? '') != 'asr';
    bool matchesLang(Map<String, dynamic> t) =>
        (t['languageCode'] as String? ?? '').toLowerCase() == _selectedLanguage.toLowerCase();
    for (var i = 0; i < tracks.length; i++) {
      if (isManual(tracks[i]) && matchesLang(tracks[i])) return i;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (isManual(tracks[i])) return i;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (matchesLang(tracks[i])) return i;
    }
    return 0;
  }

  /// Modal busy overlay used while awaiting an HTTP/parse step. The progress
  /// indicator is shown alongside `message`; the dialog isn't dismissible so
  /// the caller can `pop()` it from a known root navigator after the future
  /// resolves.
  void _showBusyOverlay(BuildContext ctx, String message) {
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(width: 16),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }

  void _dismissBusyOverlay(BuildContext ctx) {
    if (!mounted) return;
    Navigator.of(ctx, rootNavigator: true).pop();
  }

  /// Entry point wired to the closed-captions icon in dialog1's header.
  /// Prompts for a URL → fetches caption tracks → picker → downloads + parses
  /// the chosen track → opens the full-file dialog. Every long step shows a
  /// dismissible busy overlay so the rest of the app remains interactive
  /// (HTTP + parse are awaited, so the UI thread is never blocked).
  Future<void> _startYouTubeSubtitleDownload(BuildContext ctx) async {
    // Pre-fill from clipboard if it looks like a YouTube URL — common case
    // is the user just copied the link from the YouTube share sheet.
    String initial = '';
    try {
      final clip = await Clipboard.getData('text/plain');
      final t = (clip?.text ?? '').trim();
      if (_extractYouTubeVideoId(t) != null) initial = t;
    } catch (_) {}
    if (!mounted) return;

    final urlCtrl = TextEditingController(text: initial);
    final urlInput = await showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('YouTube subtitles'),
        content: TextField(
          controller: urlCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://www.youtube.com/watch?v=…  or  video id',
          ),
          keyboardType: TextInputType.url,
          onSubmitted: (v) => Navigator.of(dctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(urlCtrl.text.trim()),
            child: const Text('Fetch'),
          ),
        ],
      ),
    );
    urlCtrl.dispose();
    if (urlInput == null || urlInput.isEmpty) return;
    final videoId = _extractYouTubeVideoId(urlInput);
    if (videoId == null) {
      _showCaptureError('Not a YouTube URL',
          'Couldn\'t recognize a YouTube video id in:\n\n$urlInput');
      return;
    }
    if (!mounted) return;

    _showBusyOverlay(ctx, 'Loading caption list…');
    Map<String, dynamic> meta;
    try {
      meta = await _fetchYouTubeCaptionTracks(videoId);
    } catch (e) {
      _dismissBusyOverlay(ctx);
      _showCaptureError('Could not load captions', '$e');
      return;
    }
    _dismissBusyOverlay(ctx);

    final tracks = (meta['tracks'] as List).cast<Map<String, dynamic>>();
    if (tracks.isEmpty) {
      _showCaptureError('No captions',
          'This video has no caption tracks (neither manual nor auto-generated).');
      return;
    }
    if (!mounted) return;

    final pickedIdx = await _pickCaptionTrack(ctx, tracks);
    if (pickedIdx == null) return;
    final picked = tracks[pickedIdx];
    if (!mounted) return;

    _showBusyOverlay(ctx, 'Downloading captions…');
    List<Map<String, dynamic>> lines;
    try {
      lines = await _fetchCaptionsJson3(
        // `baseUrl` is only set on the legacy macOS WebView path; the Android
        // yt-dlp path never populates it (and `_fetchCaptionsJson3` doesn't
        // read it). Default to empty so a missing field doesn't crash.
        baseUrl: (picked['baseUrl'] as String?) ?? '',
        videoId: videoId,
        languageCode: (picked['languageCode'] as String?) ?? '',
        kind: (picked['kind'] as String?) ?? '',
      );
    } catch (e) {
      _dismissBusyOverlay(ctx);
      _showCaptureError('Could not download captions', '$e');
      return;
    }
    _dismissBusyOverlay(ctx);

    if (lines.isEmpty) {
      _showCaptureError('Empty captions',
          'The selected track returned no lines.');
      return;
    }
    if (!mounted) return;

    _showFullSubtitleDialog(
      ctx,
      lines: lines,
      sourceLang: (picked['languageCode'] as String?) ?? _selectedLanguage,
      videoUrl: 'https://www.youtube.com/watch?v=$videoId',
      videoId: videoId,
      videoTitle: (meta['title'] as String?) ?? '',
    );
  }

  /// Caption-track picker. Default-selects the track returned by
  /// `_defaultCaptionTrackIndex`. Auto-generated tracks are labeled inline so
  /// the user can spot them without expanding the row.
  Future<int?> _pickCaptionTrack(
      BuildContext ctx, List<Map<String, dynamic>> tracks) async {
    int selected = _defaultCaptionTrackIndex(tracks);
    return showDialog<int>(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) => AlertDialog(
          title: const Text('Pick caption track'),
          content: SizedBox(
            width: 360,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tracks.length,
                itemBuilder: (_, i) {
                  final t = tracks[i];
                  final isAsr = (t['kind'] as String? ?? '') == 'asr';
                  final name = (t['name'] as String? ?? '').trim();
                  final lang = (t['languageCode'] as String? ?? '').trim();
                  final label = [
                    if (name.isNotEmpty) name,
                    if (lang.isNotEmpty) '[$lang]',
                    if (isAsr) '(auto-generated)',
                  ].join(' ');
                  return RadioListTile<int>(
                    value: i,
                    groupValue: selected,
                    onChanged: (v) { if (v != null) setStateDialog(() => selected = v); },
                    title: Text(label.isEmpty ? lang : label),
                    dense: true,
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(selected),
              child: const Text('Download'),
            ),
          ],
        ),
      ),
    );
  }

  /// Full-file capture dialog: shows the entire cue list (virtualized) with
  /// a Translate-all action and Send-to-lookup. Translation is batched
  /// (~30 cues per request) so a typical episode finishes in seconds rather
  /// than minutes, with a progress counter + Cancel.
  void _showFullSubtitleDialog(
    BuildContext ctx, {
    required List<Map<String, dynamic>> lines,
    required String sourceLang,
    required String videoUrl,
    required String videoId,
    required String videoTitle,
  }) {
    final originals = lines.map((l) => (l['text'] as String)).toList();
    List<String> translation = List<String>.filled(lines.length, '');
    bool translating = false;
    bool translated = false;
    bool cancelRequested = false;
    int progressDone = 0;
    int progressTotal = lines.length;
    String? translateError;

    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) {
          final screenW = MediaQuery.of(dctx2).size.width;
          final dialogW = (screenW - 32).clamp(320.0, 1100.0);
          Future<void> startTranslate() async {
            setStateDialog(() {
              translating = true;
              cancelRequested = false;
              translateError = null;
              progressDone = 0;
              progressTotal = originals.length;
            });
            try {
              final result = await _translateLinesBatched(
                originals,
                sourceLang,
                'en',
                onProgress: (done, total) {
                  if (!mounted) return;
                  setStateDialog(() {
                    progressDone = done;
                    progressTotal = total;
                  });
                },
                isCancelled: () => cancelRequested,
              );
              if (!mounted) return;
              setStateDialog(() {
                translation = result;
                translating = false;
                translated = !cancelRequested;
              });
            } catch (e) {
              if (!mounted) return;
              setStateDialog(() {
                translateError = '$e';
                translating = false;
              });
            }
          }

          String tsFmt(double s) {
            final m = (s ~/ 60).toString().padLeft(2, '0');
            final sec = (s % 60).floor().toString().padLeft(2, '0');
            return '$m:$sec';
          }

          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        videoTitle.isNotEmpty ? videoTitle : 'YouTube subtitles',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${originals.length} lines  ·  $sourceLang → en',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    cancelRequested = true;
                    Navigator.of(dctx).pop();
                  },
                ),
              ],
            ),
            content: SizedBox(
              width: dialogW,
              height: MediaQuery.of(dctx2).size.height * 0.6,
              child: Column(
                children: [
                  if (translating)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 12),
                          Expanded(child: Text(
                            'Translating $progressDone / $progressTotal…',
                            style: const TextStyle(fontSize: 12),
                          )),
                          TextButton(
                            onPressed: () => setStateDialog(() => cancelRequested = true),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
                  if (translateError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('Translation failed: $translateError',
                          style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                    ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListView.builder(
                        itemCount: originals.length,
                        itemBuilder: (_, i) {
                          final tr = i < translation.length ? translation[i] : '';
                          final showTr = translated && tr.isNotEmpty;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    tsFmt((lines[i]['start'] as num).toDouble()),
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Text(originals[i], style: const TextStyle(fontSize: 13)),
                                      if (showTr)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(tr,
                                              style: TextStyle(
                                                  fontSize: 12, color: Colors.blue.shade800)),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: translating ? null : startTranslate,
                child: Text(translated ? 'Re-translate' : 'Translate'),
              ),
              TextButton(
                onPressed: translating ? null : () {
                  // Build the same payload shape `_jsCodeForCapturedSubtitle`
                  // expects: parallel `lines` + `translation` arrays keyed by
                  // index/start/end.
                  final outLines = <Map<String, dynamic>>[];
                  final outTr = <Map<String, dynamic>>[];
                  for (var i = 0; i < lines.length; i++) {
                    outLines.add({
                      'index': i,
                      'start': lines[i]['start'],
                      'end': lines[i]['end'],
                      'text': originals[i],
                    });
                    outTr.add({
                      'index': i,
                      'start': lines[i]['start'],
                      'end': lines[i]['end'],
                      'text': i < translation.length ? translation[i] : '',
                    });
                  }
                  Navigator.of(dctx).pop();
                  _sendCapturedSubtitleToDialog1(<String, dynamic>{
                    'query': '',
                    'sourceLang': sourceLang,
                    'targetLang': 'en',
                    'matchIndex': 0,
                    'lines': outLines,
                    'translation': outTr,
                    'videoUrl': videoUrl,
                    'videoId': videoId,
                    'videoTitle': videoTitle,
                  });
                },
                child: const Text('Send to lookup'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Translates a full-file cue list by joining cues into batches separated
  /// by newlines (cheap, terminator that Google's translator preserves in
  /// practice), translating each batch in one round trip, and splitting the
  /// response back. Falls back to per-line translation for any batch whose
  /// line count comes back wrong. 4-way concurrent across batches.
  ///
  /// Yields cooperatively after every batch completes so a long-running
  /// translation never starves the event loop / UI thread.
  Future<List<String>> _translateLinesBatched(
    List<String> lines,
    String sourceLang,
    String targetLang, {
    required void Function(int done, int total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final out = List<String>.filled(lines.length, '');
    if (lines.isEmpty) return out;

    // Pack indices into batches by character budget — Google's `gtx` accepts
    // ~5 KB per `q=` once URL-encoded, so cap at ~3500 raw chars to leave
    // headroom for multi-byte characters.
    const maxChars = 3500;
    const batchSep = '\n';
    final batches = <List<int>>[];
    var current = <int>[];
    var currentChars = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      final cost = lines[i].length + batchSep.length;
      if (current.isNotEmpty && currentChars + cost > maxChars) {
        batches.add(current);
        current = [];
        currentChars = 0;
      }
      current.add(i);
      currentChars += cost;
    }
    if (current.isNotEmpty) batches.add(current);

    Future<void> translateBatch(List<int> batch) async {
      final joined = batch.map((i) => lines[i]).join(batchSep);
      try {
        final translated = await _translateText(joined, sourceLang, targetLang);
        final parts = translated.split(batchSep);
        if (parts.length == batch.length) {
          for (var k = 0; k < batch.length; k++) {
            out[batch[k]] = parts[k];
          }
          return;
        }
        // Line-count drift — Google occasionally merges/splits cues. Fall
        // back to per-line for this batch only so the rest of the file
        // still benefits from batching.
      } catch (_) {}
      for (final i in batch) {
        if (isCancelled()) return;
        try {
          out[i] = await _translateText(lines[i], sourceLang, targetLang);
        } catch (_) {
          out[i] = '';
        }
      }
    }

    var done = 0;
    const concurrency = 4;
    for (var bi = 0; bi < batches.length; bi += concurrency) {
      if (isCancelled()) break;
      final group = batches.sublist(
        bi,
        (bi + concurrency).clamp(0, batches.length),
      );
      await Future.wait(group.map(translateBatch));
      done += group.fold<int>(0, (a, b) => a + b.length);
      onProgress(done, lines.length);
      // Yield to the event loop between batch groups so the UI stays smooth.
      await Future<void>.delayed(Duration.zero);
    }
    return out;
  }

  /// Surfaces capture-time errors above the open Filmot dialog2 via a small
  /// AlertDialog — the root ScaffoldMessenger's snackbars sit *behind* the
  /// dialog and look like "nothing happened" to the user.
  void _showCaptureError(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, maxWidth: 520),
          child: SingleChildScrollView(
            child: SelectableText(
              message,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () { Clipboard.setData(ClipboardData(text: message)); },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Scrapes the open Filmot detail page's subtitle list (`#subtitlesIn`),
  /// finds the line that matches the URL's search query, and opens a dialog
  /// where the user can adjust before/after context, translate, and hand
  /// the result to dialog1 for word-level lookup.
  Future<void> _captureFilmotSubtitle(BuildContext ctx, WebViewController controller) async {
    const js = r'''
      (function(){
        var query = '';
        try {
          // Filmot search URL: /search/%22word%22/N → first segment after
          // /search/ is the (URI-encoded) quoted query.
          var m = location.pathname.match(/\/search\/([^/]+)/);
          if (m) {
            var raw = decodeURIComponent(m[1]);
            // decodeURIComponent already converts %22 → ", so this strips
            // the literal surrounding quotes left from the filmot syntax.
            raw = raw.replace(/^["']+|["']+$/g, '');
            query = raw;
          }
        } catch(e){}
        // Identify the currently-playing video. iframe.src is the most
        // reliable signal because filmot's Next/Prev swaps the src in place.
        function ytId(href) {
          if (!href) return null;
          var pats = [
            /youtube\.com\/embed\/([A-Za-z0-9_-]{6,})/,
            /youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/,
            /youtu\.be\/([A-Za-z0-9_-]{6,})/,
            /[?&]v=([A-Za-z0-9_-]{6,})/,
            /\/sidebyside\/([A-Za-z0-9_-]{6,})/
          ];
          for (var p = 0; p < pats.length; p++) { var mmId = href.match(pats[p]); if (mmId) return mmId[1]; }
          return null;
        }
        var videoId = null;
        var ifr = document.getElementById('player');
        if (ifr && ifr.src) videoId = ytId(ifr.src);
        if (!videoId) {
          var ax = document.querySelector('#divVideoDetails a[href*="watch?v="], #linktoyoutube a[href*="watch?v="]');
          if (ax) videoId = ytId(ax.href || ax.getAttribute('href') || '');
        }
        if (!videoId) {
          var pmSb = location.pathname.match(/\/sidebyside\/([A-Za-z0-9_-]{6,})/);
          if (pmSb) videoId = pmSb[1];
        }
        var videoTitle = '';
        var titleEl = document.querySelector('#divVideoDetails .col-6');
        if (titleEl) videoTitle = (titleEl.textContent || '').trim().split(/\s*[\r\n]+/)[0].slice(0, 200);
        if (!videoTitle) videoTitle = (document.title || '').trim();
        // Filmot links the uploader as /channel/<id>, next to the title.
        var chEl = document.querySelector('#divVideoDetails a[href*="/channel/"]');
        var videoChannel = chEl ? (chEl.textContent || '').trim().slice(0, 100) : '';
        var divs = document.querySelectorAll('#subtitlesIn > div[id^="s"]');
        var lines = [];
        for (var i = 0; i < divs.length; i++) {
          var div = divs[i];
          var a = div.querySelector('a[href*="jtt("]');
          var ts = 0;
          if (a) {
            var mm = a.getAttribute('href').match(/jtt\((\d+),([\d.]+)\)/);
            if (mm) ts = parseFloat(mm[2]);
          }
          var clone = div.cloneNode(true);
          var anc = clone.querySelector('a');
          if (anc) anc.parentNode.removeChild(anc);
          var text = (clone.textContent || '').replace(/ /g, ' ').replace(/\s+/g, ' ').trim();
          var idM = div.id.match(/^s(\d+)/);
          lines.push({ i: idM ? parseInt(idM[1], 10) : i, ts: ts, t: text });
        }
        // --- Robust match resolution ---
        // Filmot does fuzzy/stemmed search across word forms (esp. in highly
        // inflected languages like Swedish), so an exact substring lookup on
        // the query word often misses. Try a cascade of strategies and remember
        // which one fired so the UI can flag fallbacks.
        function stripDiacritics(s) {
          try { return s.normalize('NFD').replace(/[̀-ͯ]/g, ''); }
          catch(e) { return s; }
        }
        function findMatch(lines, query) {
          if (!query) return { idx: -1, reason: 'no-query' };
          var q = query.toLowerCase();
          // 1) Exact substring.
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].t.toLowerCase().indexOf(q) !== -1) return { idx: i, reason: 'exact' };
          }
          // 2) Diacritic-insensitive substring (e.g. "atgang" matches "åtgång").
          var qs = stripDiacritics(q);
          if (qs !== q) {
            for (var i2 = 0; i2 < lines.length; i2++) {
              if (stripDiacritics(lines[i2].t.toLowerCase()).indexOf(qs) !== -1) return { idx: i2, reason: 'normalized' };
            }
          }
          // 3) Stemmed prefix — drop trailing chars to catch inflections
          // ("vakna" should match "vaknade", "vaknar", "vaknat", "vakn-up", ...).
          for (var trim = 1; trim <= 4 && q.length - trim >= 3; trim++) {
            var qt = stripDiacritics(q.substring(0, q.length - trim));
            for (var i3 = 0; i3 < lines.length; i3++) {
              if (stripDiacritics(lines[i3].t.toLowerCase()).indexOf(qt) !== -1) return { idx: i3, reason: 'stem(-' + trim + ')' };
            }
          }
          // 4) Word-overlap — for multi-word queries, find the line containing
          // the largest number of query tokens.
          var tokens = q.split(/\s+/).filter(function(w){ return w.length > 1; });
          if (tokens.length > 1) {
            var best = -1, bestN = 0;
            for (var i4 = 0; i4 < lines.length; i4++) {
              var lt = stripDiacritics(lines[i4].t.toLowerCase());
              var n = 0;
              for (var t = 0; t < tokens.length; t++) {
                if (lt.indexOf(stripDiacritics(tokens[t])) !== -1) n++;
              }
              if (n > bestN) { bestN = n; best = i4; }
            }
            if (best >= 0 && bestN >= Math.max(1, Math.ceil(tokens.length / 2))) {
              return { idx: best, reason: 'tokens(' + bestN + '/' + tokens.length + ')' };
            }
          }
          return { idx: -1, reason: 'no-match' };
        }
        var resolved = findMatch(lines, query);
        var matchIdx = resolved.idx;
        var matchReason = resolved.reason;
        // 5) Time-based fallback — anchor at whatever subtitle is playing right now.
        if (matchIdx < 0 && lines.length) {
          try {
            var ct = null;
            if (window.player && typeof window.player.getCurrentTime === 'function') {
              ct = window.player.getCurrentTime();
            }
            if (typeof ct === 'number' && ct >= 0) {
              for (var ti = 0; ti < lines.length; ti++) {
                var nxt = (ti + 1 < lines.length) ? lines[ti + 1].ts : (lines[ti].ts + 3);
                if (ct >= lines[ti].ts && ct < nxt) { matchIdx = ti; matchReason = 'currentTime'; break; }
              }
              if (matchIdx < 0) { matchIdx = lines.length - 1; matchReason = 'currentTime'; }
            }
          } catch(e) {}
        }
        // 6) Last resort: first non-empty line.
        if (matchIdx < 0) {
          for (var fi = 0; fi < lines.length; fi++) {
            if ((lines[fi].t || '').trim().length) { matchIdx = fi; matchReason = 'firstNonEmpty'; break; }
          }
        }
        return JSON.stringify({
          query: query,
          lines: lines,
          matchIdx: matchIdx,
          matchReason: matchReason,
          videoId: videoId || '',
          videoUrl: videoId ? ('https://www.youtube.com/watch?v=' + videoId) : '',
          videoTitle: videoTitle,
          videoChannel: videoChannel
        });
      })();
    ''';
    // Retry the scrape a few times — when filmot navigates Next/Prev it
    // does a full page load and its own subtitle population may finish
    // slightly after onPageFinished. Without a retry the user often gets
    // an empty result on the first tap right after navigation.
    Map<String, dynamic>? data;
    Object? lastErr;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final raw = await controller.runJavaScriptReturningResult(js);
        var s = raw.toString();
        if (s.startsWith('"') && s.endsWith('"')) s = jsonDecode(s) as String;
        final d = jsonDecode(s) as Map<String, dynamic>;
        final lines = (d['lines'] as List?) ?? const [];
        if (lines.isNotEmpty) { data = d; break; }
        // Empty page DOM — keep the last seen `d` in case all retries miss.
        data = d;
      } catch (e) {
        lastErr = e;
      }
      if (attempt < 3) await Future.delayed(const Duration(milliseconds: 500));
    }
    if (data == null) {
      _showCaptureError('Capture failed', 'Could not read the subtitle list.\n\n$lastErr');
      return;
    }
    final linesRaw = (data['lines'] as List?) ?? const [];
    final query = (data['query'] ?? '').toString();
    var matchIdx = (data['matchIdx'] as num?)?.toInt() ?? -1;
    final matchReason = (data['matchReason'] ?? '').toString();
    final videoUrl = (data['videoUrl'] ?? '').toString();
    final videoId = (data['videoId'] ?? '').toString();
    final videoTitle = cleanCapturedTitle((data['videoTitle'] ?? '').toString());
    if (linesRaw.isEmpty) {
      _showCaptureError(
        'No subtitle lines',
        'Filmot has not loaded any subtitle lines on this page yet '
        '(or this video has no captions). Wait a moment for the page '
        'to settle and try again — if the player works, the captions '
        'usually appear shortly after.',
      );
      return;
    }
    // The JS-side cascade should always have set matchIdx to something
    // sensible when lines exist. If not (all-empty subtitle text, etc.),
    // anchor on the first line so the user can still adjust manually.
    if (matchIdx < 0) matchIdx = 0;
    // Build structured {index, start, end, text} for every line in the page.
    // End-time = next line's start (within the captured range we'll slice).
    // For the absolute last line we add a 3s tail.
    final allLines = <Map<String, dynamic>>[];
    for (var i = 0; i < linesRaw.length; i++) {
      final l = linesRaw[i] as Map<String, dynamic>;
      allLines.add({
        'index': (l['i'] as num?)?.toInt() ?? i,
        'start': (l['ts'] as num?)?.toDouble() ?? 0.0,
        'text': (l['t'] ?? '').toString(),
        'end': 0.0,
      });
    }
    for (var i = 0; i < allLines.length; i++) {
      if (i + 1 < allLines.length) {
        allLines[i]['end'] = allLines[i + 1]['start'];
      } else {
        allLines[i]['end'] = (allLines[i]['start'] as double) + 3.0;
      }
    }
    if (!mounted) return;
    _showSubtitleCaptureDialog(
      ctx,
      query: query,
      allLines: allLines,
      matchIdx: matchIdx,
      matchReason: matchReason,
      videoUrl: videoUrl,
      videoId: videoId,
      videoTitle: videoTitle,
      videoChannel: (data['videoChannel'] ?? '').toString(),
    );
  }

  void _showSubtitleCaptureDialog(BuildContext ctx, {
    required String query,
    required List<Map<String, dynamic>> allLines,
    required int matchIdx,
    required String matchReason,
    required String videoUrl,
    required String videoId,
    required String videoTitle,
    String videoChannel = '',
  }) {
    // matchIdx is mutable — the user can change the anchor line manually
    // via the picker below.
    int currentMatchIdx = matchIdx;
    String currentMatchReason = matchReason;
    int before = 2;
    int after = 2;
    // Parallel to the captured-range slice. Empty list = not translated yet.
    List<String> translation = const [];
    String? translationSource; // 'google' | 'on-device'
    bool translating = false;
    bool preferOnDevice = false;
    String? translateError;
    // Memo key — if before/after changes after a translation, invalidate it.
    String? translatedFor;
    // Per-line editable text. Keyed by `allLines` index so original edits
    // survive slider changes (the underlying `allLines` entry persists).
    // Translation controllers are keyed the same way but rebuilt whenever
    // the range changes (translation itself is range-scoped and invalidates).
    final Map<int, TextEditingController> origCtrls = {};
    final Map<int, TextEditingController> trCtrls = {};
    void disposeTrCtrls() { for (final c in trCtrls.values) { c.dispose(); } trCtrls.clear(); }
    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) {
          final start = (currentMatchIdx - before).clamp(0, allLines.length - 1);
          final end = (currentMatchIdx + after).clamp(0, allLines.length - 1);
          final captured = allLines.sublist(start, end + 1);
          final capturedKey = '$start-$end';
          if (translatedFor != null && translatedFor != capturedKey) {
            // Range changed — stale translation; clear it.
            translation = const [];
            translatedFor = null;
            translationSource = null;
            disposeTrCtrls();
          }
          // Ensure an original-text controller for each currently-visible line.
          // Stable key = allLines index, so a controller (and its edited text)
          // is retained when the slider expands/contracts the visible range.
          for (final line in captured) {
            final idx = line['index'] as int;
            origCtrls.putIfAbsent(idx, () => TextEditingController(text: (line['text'] as String)));
          }
          // After a translate(), build a parallel set of translation controllers
          // (one per visible line). Done once per fresh translation.
          if (translation.length == captured.length && translatedFor == capturedKey && trCtrls.isEmpty) {
            for (var i = 0; i < captured.length; i++) {
              final idx = captured[i]['index'] as int;
              trCtrls[idx] = TextEditingController(text: translation[i]);
            }
          }
          final matchTs = (allLines[currentMatchIdx]['start'] as num?)?.toDouble() ?? 0;
          final mmss = '${(matchTs ~/ 60).toString().padLeft(2,'0')}:${(matchTs % 60).floor().toString().padLeft(2,'0')}';
          final screenW = MediaQuery.of(dctx2).size.width;
          final dialogW = (screenW - 32).clamp(320.0, 1100.0);
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        query.isEmpty ? mmss : '"$query"  ·  $mmss',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (videoTitle.isNotEmpty || videoUrl.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            videoTitle.isNotEmpty ? videoTitle : videoUrl,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontWeight: FontWeight.normal),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(dctx).pop(),
                ),
              ],
            ),
            content: SizedBox(
              width: dialogW,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(width: 60, child: Text('Anchor')),
                        Expanded(
                          child: Text(
                            '${(allLines[currentMatchIdx]['start'] as num).toStringAsFixed(1)}s  ·  '
                            '${(allLines[currentMatchIdx]['text'] as String)}',
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.list, size: 16),
                          label: const Text('Change'),
                          onPressed: () => _pickAnchorLine(
                            dctx2,
                            allLines: allLines,
                            current: currentMatchIdx,
                            onPicked: (i) => setStateDialog(() {
                              currentMatchIdx = i;
                              currentMatchReason = 'manual';
                            }),
                          ),
                        ),
                      ],
                    ),
                    if (currentMatchReason.isNotEmpty && currentMatchReason != 'exact' && currentMatchReason != 'normalized')
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(
                          query.isEmpty
                              ? 'Anchored via ${currentMatchReason} (no /search/ query in URL — pick manually if needed)'
                              : 'No exact match for "$query" — anchored via ${currentMatchReason}. Pick manually if this isn\'t right.',
                          style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(children: [
                      const SizedBox(width: 110, child: Text('Lines Before')),
                      _lineCountPicker(value: before, onChanged: (v) => setStateDialog(() => before = v)),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      const SizedBox(width: 110, child: Text('Lines After')),
                      _lineCountPicker(value: after, onChanged: (v) => setStateDialog(() => after = v)),
                    ]),
                    const Divider(),
                    Text('Captured (${end - start + 1} lines)', style: Theme.of(dctx2).textTheme.titleSmall),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      width: double.infinity,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(4)),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: List.generate(captured.length, (i) {
                            final line = captured[i];
                            final idx = line['index'] as int;
                            final ctrl = origCtrls[idx]!;
                            return _editableLineRow(
                              ts: (line['start'] as num).toDouble(),
                              controller: ctrl,
                              onChanged: (v) { line['text'] = v; },
                            );
                          }),
                        ),
                      ),
                    ),
                    if (translateError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(translateError!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                      ),
                    Row(
                      children: [
                        Checkbox(
                          value: preferOnDevice,
                          onChanged: (v) => setStateDialog(() => preferOnDevice = v ?? false),
                        ),
                        const Expanded(child: Text('Use on-device translation (ML Kit, offline)', style: TextStyle(fontSize: 12))),
                      ],
                    ),
                    if (translation.isNotEmpty) ...[
                      Text(
                        'Translation ($_selectedLanguage → en)${translationSource != null ? "  ·  via $translationSource" : ""}',
                        style: Theme.of(dctx2).textTheme.titleSmall,
                      ),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 220),
                        width: double.infinity,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(border: Border.all(color: Colors.blue), borderRadius: BorderRadius.circular(4)),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(captured.length, (i) {
                              final line = captured[i];
                              final idx = line['index'] as int;
                              final ctrl = trCtrls[idx];
                              if (ctrl == null) return const SizedBox.shrink();
                              return _editableLineRow(
                                ts: (line['start'] as num).toDouble(),
                                controller: ctrl,
                                onChanged: (v) {
                                  if (i < translation.length) translation[i] = v;
                                },
                              );
                            }),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: translating || captured.isEmpty ? null : () async {
                  setStateDialog(() { translating = true; translateError = null; });
                  try {
                    final perLine = await _translateLines(
                      captured.map((l) => (l['text'] as String)).toList(),
                      _selectedLanguage,
                      'en',
                      preferOnDevice: preferOnDevice,
                    );
                    setStateDialog(() {
                      translation = perLine;
                      translatedFor = capturedKey;
                      translationSource = preferOnDevice ? 'on-device (ML Kit)' : 'google (with on-device fallback)';
                      translating = false;
                    });
                  } catch (e) {
                    setStateDialog(() {
                      translateError = 'Translation failed: $e';
                      translating = false;
                    });
                  }
                },
                child: Text(translating ? 'Translating…' : (preferOnDevice ? 'Translate (on-device)' : 'Translate')),
              ),
              TextButton(
                onPressed: captured.isEmpty ? null : () {
                  Navigator.of(dctx).pop();
                  // Build a translation array parallel to `captured` so the
                  // page can zip them positionally — empty strings preserve
                  // the alignment when a line wasn't translatable.
                  final translationArr = <Map<String, dynamic>>[];
                  for (var i = 0; i < captured.length; i++) {
                    translationArr.add({
                      'index': captured[i]['index'],
                      'start': captured[i]['start'],
                      'end': captured[i]['end'],
                      'text': i < translation.length ? translation[i] : '',
                    });
                  }
                  _sendCapturedSubtitleToDialog1(<String, dynamic>{
                    'query': query,
                    'sourceLang': _selectedLanguage,
                    'targetLang': 'en',
                    'matchIndex': currentMatchIdx - start,
                    'lines': captured,
                    'translation': translationArr,
                    'videoUrl': videoUrl,
                    'videoId': videoId,
                    'videoTitle': videoTitle,
                    if (videoChannel.isNotEmpty) 'channel': videoChannel,
                  });
                },
                child: const Text('Send to lookup'),
              ),
            ],
          );
        },
      ),
    ).then((_) {
      for (final c in origCtrls.values) { c.dispose(); }
      for (final c in trCtrls.values) { c.dispose(); }
      origCtrls.clear();
      trCtrls.clear();
    });
  }

  /// Opens a list of all subtitle lines on the page and lets the user pick
  /// one as the anchor for the captured range. Used when the auto-matcher's
  /// pick is wrong (fuzzy match landed on the wrong line, no /search/ query
  /// in URL, etc.). Supports a quick text filter.
  void _pickAnchorLine(BuildContext ctx, {
    required List<Map<String, dynamic>> allLines,
    required int current,
    required ValueChanged<int> onPicked,
  }) {
    String filter = '';
    showDialog(
      context: ctx,
      builder: (pctx) => StatefulBuilder(
        builder: (pctx2, setSt) {
          final f = filter.trim().toLowerCase();
          final visible = <int>[];
          for (var i = 0; i < allLines.length; i++) {
            final t = (allLines[i]['text'] as String).trim();
            if (t.isEmpty) continue;
            if (f.isEmpty || t.toLowerCase().contains(f)) visible.add(i);
          }
          return AlertDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            title: const Text('Pick anchor line'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Filter…',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                    ),
                    onChanged: (v) => setSt(() => filter = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, vi) {
                        final i = visible[vi];
                        final l = allLines[i];
                        final ts = (l['start'] as num).toDouble();
                        return ListTile(
                          dense: true,
                          selected: i == current,
                          leading: SizedBox(
                            width: 44,
                            child: Text(
                              '${ts.toStringAsFixed(1)}s',
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            ),
                          ),
                          title: Text(l['text'] as String, style: const TextStyle(fontSize: 12)),
                          onTap: () {
                            Navigator.of(pctx).pop();
                            onPicked(i);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(pctx).pop(), child: const Text('Cancel')),
            ],
          );
        },
      ),
    );
  }

  /// One editable row: a timestamp label and a borderless TextField that
  /// fills the rest of the width. The line and its timestamp stay 1:1 so
  /// edits don't break SRT mapping.
  Widget _editableLineRow({
    required double ts,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, right: 4),
            child: Text(
              '${ts.toStringAsFixed(1)}s',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(fontSize: 13),
            maxLines: null,
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  /// A compact dropdown that lets the user pick a number in 0..15. Used in
  /// the capture dialog instead of sliders so the value is selectable.
  Widget _lineCountPicker({required int value, required ValueChanged<int> onChanged}) {
    return DropdownButton<int>(
      value: value.clamp(0, 15),
      isDense: true,
      items: List.generate(16, (i) => DropdownMenuItem<int>(value: i, child: Text('$i'))),
      onChanged: (v) { if (v != null) onChanged(v); },
    );
  }

  Future<void> _saveCurrentFilmotVideo(String dialogId, WebViewController controller) async {
    // Filmot's search-results page hosts the player at the top and a list of
    // result cards in a sidebar. Clicking "Next video" swaps the iframe `src`
    // and the `#divVideoDetails` content via JS — the page URL does not
    // change. So derive the *currently playing* video id from the live iframe
    // first, then fall back to other signals.
    const js = r'''
      (function(){
        function ytIdFromAny(href) {
          if (!href) return null;
          var pats = [
            /youtube\.com\/embed\/([A-Za-z0-9_-]{6,})/,
            /youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/,
            /youtu\.be\/([A-Za-z0-9_-]{6,})/,
            /[?&]v=([A-Za-z0-9_-]{6,})/,
            /\/sidebyside\/([A-Za-z0-9_-]{6,})/,
            /\/(?:video|watch)\/([A-Za-z0-9_-]{6,})/
          ];
          for (var i = 0; i < pats.length; i++) { var m = href.match(pats[i]); if (m) return m[1]; }
          return null;
        }
        function packFor(id, fallbackTitle) {
          var ch = (window.__cupitorVideoChannel || {})[id] || '';
          var tEl = document.querySelector('#divVideoDetails .col-6');
          var t = tEl ? (tEl.textContent || '').trim().split(/\s*[\r\n]+/)[0].slice(0, 200) : '';
          if (!t) t = (fallbackTitle || document.title || '').trim().slice(0, 200);
          return JSON.stringify({ url: 'https://www.youtube.com/watch?v=' + id, channel: ch, title: t });
        }
        // 1. The live iframe is the most reliable signal — it always reflects
        //    the currently playing video, including after a JS-driven "Next".
        var ifr = document.getElementById('player');
        if (ifr && ifr.src) {
          var id1 = ytIdFromAny(ifr.src);
          if (id1) return packFor(id1, '');
        }
        // 2. The "Open on youtube:" / external-link anchor in #divVideoDetails
        //    updates alongside the iframe.
        var detailA = document.querySelector('#divVideoDetails a[href*="watch?v="], #linktoyoutube a[href*="watch?v="]');
        if (detailA) {
          var id2 = ytIdFromAny(detailA.href || detailA.getAttribute('href') || '');
          if (id2) return packFor(id2, detailA.textContent || '');
        }
        // 3. URL-based: only true on the standalone /sidebyside/ detail page.
        var pm = location.pathname.match(/\/sidebyside\/([A-Za-z0-9_-]{6,})/);
        if (pm) return packFor(pm[1], '');
        // 4. Last resort — pick the vcard nearest the viewport center.
        var cards = Array.prototype.slice.call(document.querySelectorAll('[id^="vcard_"]'));
        var center = window.innerHeight / 2;
        var best = null, bestDist = Infinity;
        for (var i = 0; i < cards.length; i++) {
          var c = cards[i];
          var r = c.getBoundingClientRect();
          if (r.bottom < 0 || r.top > window.innerHeight) continue;
          var d = Math.abs((r.top + r.bottom) / 2 - center);
          if (d < bestDist) { bestDist = d; best = c; }
        }
        if (!best) return JSON.stringify({});
        var id4 = best.id.replace(/^vcard_/, '');
        var titleA = best.querySelector('a[id^="vlink"]');
        return packFor(id4, titleA ? titleA.textContent || '' : '');
      })();
    ''';
    try {
      final raw = await controller.runJavaScriptReturningResult(js);
      // Returned as a JSON string (double-encoded on some platforms).
      var s = raw.toString();
      if (s.startsWith('"') && s.endsWith('"')) {
        s = jsonDecode(s) as String;
      }
      final data = jsonDecode(s) as Map<String, dynamic>;
      final url = data['url']?.toString() ?? '';
      if (url.isEmpty) {
        _showDialog2SnackBar(dialogId, 'No video URL found on screen');
        return;
      }
      _handleFilmotMessage(dialogId, jsonEncode({
        'action': 'saveVideo',
        'url': url,
        'channel': data['channel']?.toString() ?? '',
        'title': data['title']?.toString() ?? '',
      }));
    } catch (e) {
      _showDialog2SnackBar(dialogId, 'Save failed: $e');
    }
  }

  void _showSavedVideosDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setStateDialog) => AlertDialog(
          title: Text('Saved videos (${_savedVideos.length})'),
          content: SizedBox(
            width: double.maxFinite,
            child: _savedVideos.isEmpty
                ? Text('Nothing saved yet.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _savedVideos.length,
                    itemBuilder: (_, i) {
                      final v = _savedVideos[i];
                      final title = v['title']?.isNotEmpty == true ? v['title']! : v['url']!;
                      final subtitle = [v['channel'], v['url']].where((s) => s != null && s.isNotEmpty).join(' · ');
                      return ListTile(
                        dense: true,
                        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11)),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, size: 20),
                          onPressed: () {
                            setState(() => _savedVideos.removeAt(i));
                            _saveSavedVideos();
                            setStateDialog(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: _savedVideos.isEmpty ? null : () {
                final urls = _savedVideos.map((v) => v['url']).whereType<String>().join('\n');
                Clipboard.setData(ClipboardData(text: urls));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Copied ${_savedVideos.length} URLs'), duration: const Duration(seconds: 2)),
                );
              },
              child: Text('Copy URLs'),
            ),
            TextButton(
              onPressed: _savedVideos.isEmpty ? null : () {
                final lines = _savedVideos.map((v) {
                  return [v['title'] ?? '', v['channel'] ?? '', v['url'] ?? '', v['savedAt'] ?? '']
                      .map((s) => s.replaceAll('"', '""'))
                      .map((s) => '"$s"')
                      .join(',');
                }).join('\n');
                final header = '"title","channel","url","savedAt"\n';
                Clipboard.setData(ClipboardData(text: header + lines));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Copied CSV'), duration: const Duration(seconds: 2)),
                );
              },
              child: Text('Copy CSV'),
            ),
            TextButton(
              onPressed: _savedVideos.isEmpty ? null : () {
                showDialog(
                  context: dctx,
                  builder: (cctx) => AlertDialog(
                    title: Text('Clear all saved videos?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(cctx).pop(), child: Text('Cancel')),
                      TextButton(
                        onPressed: () {
                          setState(() => _savedVideos.clear());
                          _saveSavedVideos();
                          setStateDialog(() {});
                          Navigator.of(cctx).pop();
                        },
                        child: Text('Clear'),
                      ),
                    ],
                  ),
                );
              },
              child: Text('Clear'),
            ),
            TextButton(onPressed: () => Navigator.of(dctx).pop(), child: Text('Close')),
          ],
        ),
      ),
    );
  }

  // ---------- end Filmot helpers ----------

  String getUrlForLanguage(String lang) {
    return _dialogUrl + '?lang=' + (_languageParams[lang] ?? lang);
  }

  /// Handles a GitHub API proxy request from the JS channel.
  /// The message is JSON: { id, method, path, body? }
  /// Flutter adds the Authorization header, makes the call, and posts the
  /// response back via JS so the token is never exposed to the page.
  Future<void> _handleGitHubProxyRequest(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try {
      req = jsonDecode(msg.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final id = req['id'] as String? ?? '';
    final method = (req['method'] as String? ?? 'GET').toUpperCase();
    final path = req['path'] as String? ?? '';
    final bodyStr = req['body'] as String?;
    final url = 'https://api.github.com$path';
    final token = _githubToken ?? '';

    String responseBody;
    int statusCode;
    try {
      final uri = Uri.parse(url);
      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (bodyStr != null) 'Content-Type': 'application/json',
      };
      http.Response response;
      switch (method) {
        case 'GET':
          response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
          break;
        case 'PUT':
          response = await http.put(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          response = await http.post(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'PATCH':
          response = await http.patch(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        case 'DELETE':
          response = await http.delete(uri, headers: headers, body: bodyStr).timeout(const Duration(seconds: 15));
          break;
        default:
          // Previously fell through to GET, which silently turned PATCH /
          // DELETE writes into reads — proxy returned 200 with the
          // current resource and the actual write never happened.
          throw Exception('GitHubProxy: unsupported HTTP method "$method"');
      }
      responseBody = response.body;
      statusCode = response.statusCode;
    } catch (e) {
      responseBody = jsonEncode({'message': e.toString()});
      statusCode = 0;
    }

    // Escape the response to embed safely in a JS string template
    final escaped = jsonEncode(responseBody); // produces a quoted, escaped JSON string
    final js = '''
      (function() {
        const handler = window._ghProxyHandlers && window._ghProxyHandlers['$id'];
        if (handler) {
          delete window._ghProxyHandlers['$id'];
          handler($statusCode, $escaped);
        }
      })();
    ''';
    dialogController?.runJavaScript(js);
  }

  void _openDialogWithWebview(String text) {
    _currentDialogText = text;
    if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
    if (dialogController != null) {
      dialogController?.runJavaScript(jsCodeToFilterData(text));
    } else {
      _dialog1Loaded = false;
      dialogController = WebViewController()
        ..configureForMac()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(_userAgent)
        ..addJavaScriptChannel('GitHubProxy', onMessageReceived: _handleGitHubProxyRequest)
        ..addJavaScriptChannel('TtsBridge', onMessageReceived: _handleTtsBridge)
        ..addJavaScriptChannel('MediaState', onMessageReceived: _handleMediaStateBridge)
        ..addJavaScriptChannel('AudioBridge', onMessageReceived: _handleAudioBridge)
        // Dictation for the manual-card editor's Source/Target fields. The
        // webapp feature-detects this channel and hides its 🎤 buttons when
        // it's absent, so registering it is what turns the feature on.
        // Protocol: docs/speech-bridge-spec.md.
        ..addJavaScriptChannel('SpeechBridge', onMessageReceived: _handleSpeechBridge)
        // The study page (trexsatya.github.io/language.html) loads in THIS
        // (dialog) controller, so its 🌐 translate button needs the channel
        // here too. The main _controller registers TranslateRequest as well,
        // but that controller isn't the one hosting the study app. The handler
        // (_handleTranslateRequest → window.__cupTranslated) is shared.
        ..addJavaScriptChannel('TranslateRequest', onMessageReceived: _handleTranslateRequest)
        ..addJavaScriptChannel('LinkLongPress', onMessageReceived: (msg) => _handleLinkLongPress(msg.message))
        // Language-app ↔ Cupitor bridge for the playlist feature.
        //   { op: 'getPlaylists' } → Cupitor pushes the full playlists
        //     payload as a `cupitorPlaylists` CustomEvent.
        //   { op: 'openEpub', book_key, chapter_idx } → Cupitor closes
        //     dialog1 and opens the EPUB reader at the given chapter.
        ..addJavaScriptChannel('PlaylistBridge',
            onMessageReceived: (msg) => _handlePlaylistBridge(msg.message))
        // Language-app ↔ Cupitor bridge for the notification feature.
        // Ops + events: spec §Bridge. Acks via cupitorNotifAck.
        ..addJavaScriptChannel('NotifBridge',
            onMessageReceived: (msg) => _notifBridge.handle(msg.message))
        // Same log sink as the main WebView, so the scroll probe (and any
        // other page-side diagnostic) can report from inside dialog1.
        ..addJavaScriptChannel('SnippetLogChannel',
            onMessageReceived: _onSnippetLogMessage)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (url) {
              _dialogErrorNotifier.value = null;
              // The page being replaced takes its JS state with it, so no
              // recordStop/recordCancel is ever coming for a clip it had in
              // progress — and a dictation's pending promise dies with it.
              // Reload, retry and the language switch all land here.
              // Reply rather than tearing down silently: onPageStarted also
              // fires for redirect hops, where the page survives and would
              // otherwise be left waiting on a promise nothing can settle.
              // 'cancelled' is silent on that side, and a reply to a page
              // that really is gone costs nothing.
              _sttCancelForMicHandoff();
              _stopNativeRecordingIfAny();
              _injectYouTubeAdBlocker(dialogController);
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame == true) {
                _dialogErrorNotifier.value = '[${error.errorCode}] ${error.description}\n${error.url ?? ''}';
              }
            },
            onNavigationRequest: (request) {
              if (!request.isMainFrame) return NavigationDecision.navigate;
              final rewritten = _rewriteYouTubeUrl(request.url);
              if (rewritten != null) {
                // YouTube link clicked inside the lookup dialog — open it on
                // the chosen front-end in dialog2 (different host from
                // _dialogUrl so it falls through to the dialog2 branch below).
                _openDialog2WithWebview(rewritten);
                return NavigationDecision.prevent;
              }
              final reqHost = Uri.tryParse(request.url)?.host;
              final dialogHost = Uri.tryParse(_dialogUrl)?.host;
              if (reqHost != dialogHost) {
                _openDialog2WithWebview(request.url);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onPageFinished: (url) {
              _injectAdBlocker(dialogController);
              // Let this WebView answer its own requests for the background
              // music files. Attached per page load because a fresh dialog
              // WebView starts unwrapped.
              _attachLocalMedia();
              dialogController?.runJavaScript(_linkLongPressJs);
              // Polyfill window.speechSynthesis before the page tries to use
              // it. Safe to inject every page-finished — re-entry is gated.
              dialogController?.runJavaScript(_ttsPolyfillJs);
              // Media-key shim: forwards headset events to YT IFrame API and
              // reports YT player state back to native MediaSession.
              dialogController?.runJavaScript(_mediaKeysShimJs);
              // Auto-unmute any YouTube/HTML5 media that autoplayed muted.
              dialogController?.runJavaScript(_autoUnmuteYouTubeJs);
              // Activate the MediaSession while we're on our language page
              // (where the YT iframe lives). Other hosts deactivate so we
              // don't steal media keys from other apps in the background.
              final onLanguagePage = url.startsWith(_dialogUrl);
              _setMediaSessionActive(onLanguagePage);
              dialogController?.runJavaScript(jsCodeToFilterData(_currentDialogText));
              final pending = _pendingCapturedSubtitle;
              if (pending != null) {
                _pendingCapturedSubtitle = null;
                dialogController?.runJavaScript(_jsCodeForCapturedSubtitle(pending));
              }
              _dialog1Loaded = true;
              if (_pendingCaptionCaptures.isNotEmpty) {
                final queued =
                    List<Map<String, dynamic>>.from(_pendingCaptionCaptures);
                _pendingCaptionCaptures.clear();
                for (final d in queued) {
                  dialogController?.runJavaScript(_jsCodeForCaptionCapture(d));
                }
              }
              // Warm the language app with the current playlist state
              // so it can render manual cards without an explicit fetch.
              _pushPlaylistsToDialog();
              _pushNotifStateToDialog();
              _injectScrollDiag(dialogController, 'dialog1');
              // Notification tap that triggered this load: deliver the
              // opened-event to the page now that its JS context exists.
              final pendingOpened = _pendingNotifOpenedEvent;
              if (pendingOpened != null) {
                _pendingNotifOpenedEvent = null;
                _emitNotifEvent('cupitorNotificationOpened', pendingOpened);
              }
            },
          ),
        )
        ..loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
      _enableThirdPartyCookies(dialogController!);
    }

    // Always show the dialog (it may have been dismissed previously)
    _showDialog1();
    // dialog1 adds a WebView the startup pass could not have seen.
    _installRenderGuardSoon();
  }

  /// Notification body tap: open dialog1 AT [url] (spec: open_url). This is
  /// a NAVIGATION — it must not go through [_openDialogWithWebview], whose
  /// argument is dictionary-lookup text (the page would "search" for the
  /// URL string instead of loading it).
  void _openDialogAtUrl(String url) {
    final uri = Uri.tryParse(url);
    if (dialogController == null) {
      // Builds the controller + shows the dialog; empty text keeps the
      // lookup filter and clipboard untouched.
      _openDialogWithWebview('');
    } else {
      _currentDialogText = '';
      _showDialog1();
    }
    if (uri != null && uri.hasScheme) {
      dialogController?.loadRequest(uri);
    }
  }

  void _showDialog1() {
    if (dialogController == null) return;
    // Already on screen — nothing to push. The caller's content update via
    // dialogController.runJavaScript will reach the live WebView regardless.
    if (_dialog1Visible) {
      if (_dialog1Minimized) setState(() => _dialog1Minimized = false);
      return;
    }
    setState(() => _dialog1Minimized = false);
    _bumpMinimizedVersion();
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // If dialog has been minimized before, tapping outside should minimize, not close
    final hasBeenMinimized = _dialog1EverMinimized;
    _dialog1Visible = true;

    showDialog(
      context: context,
      barrierDismissible: !hasBeenMinimized, // Prevent outside tap closing if ever minimized
      // Allow the dialog to extend behind the status / nav bars so it
      // covers the full screen height; otherwise the system insets clip
      // about ~50 px off the top + bottom on Android.
      useSafeArea: false,
      builder: (ctx) {
        // Captured here because this is the only place the route object is
        // reachable; showDialog does not hand it back.
        _dialog1Route = ModalRoute.of(ctx);
        return ValueListenableBuilder<bool>(
        // Fullscreen toggle lives outside the outer State's setState scope
        // (this is a separate Navigator route), so we drive it from a notifier.
        valueListenable: _dialog1FullscreenNotifier,
        builder: (_, fullscreen, __) {
          final dialog = Dialog(
            // vertical: 0 in both modes — the user wants the dialog edge
            // to reach the top and bottom of the device. The non-
            // fullscreen mode keeps a tiny 1 % horizontal inset so the
            // close/minimize chrome sits inside the rounded corners.
            insetPadding: fullscreen
                ? EdgeInsets.zero
                : EdgeInsets.symmetric(horizontal: screenWidth * 0.01, vertical: 0),
            shape: fullscreen
                ? const RoundedRectangleBorder(borderRadius: BorderRadius.zero)
                : null,
            child: fullscreen
                ? Stack(children: [
                    _buildDialog1Content(ctx, screenWidth, screenHeight),
                    // The only control left on screen: back to the normal
                    // dialog, toolbar and all. Draggable, so it can be moved
                    // off whatever part of the page it covers.
                    TagCaptureFloatingChip(
                      armed: false,
                      idleIcon: Icons.fullscreen_exit,
                      idleColor: const Color(0xCCE0E0E0),
                      initialPos: _dialog1FsExitPos,
                      onTap: () => _dialog1FullscreenNotifier.value = false,
                      onHide: () => _dialog1FullscreenNotifier.value = false,
                      onMoved: (p) => _dialog1FsExitPos = p,
                    ),
                  ])
                : _buildDialog1Content(ctx, screenWidth, screenHeight),
          );
          if (!hasBeenMinimized) return dialog;
          // Custom barrier tap handler — minimizes instead of closing.
          return GestureDetector(
            onTap: () {
              setState(() => _dialog1Minimized = true);
              Navigator.of(ctx).pop();
              _bumpMinimizedVersion();
            },
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: GestureDetector(
                  onTap: () {}, // Prevent tap propagation from dialog content
                  child: dialog,
                ),
              ),
            ),
          );
        },
        );
      },
    ).then((_) {
      // Dialog closed - but keep controller alive to avoid reloading.
      // Controller will be cleaned up only when app is disposed or language changes.
      // This prevents unnecessary reloads when reopening the dialog.
      _dialog1Visible = false;
      _dialog1Route = null;
      _dialog1FullscreenNotifier.value = false;
      _releaseVideosAfterLookup();
      // Release the mic, and ANSWER the page rather than tearing down
      // silently: the controller deliberately outlives the dialog (and this
      // also runs on minimize), so the webapp is still alive holding a
      // pending promise. Drop it and its 🎤 button pulses forever and blocks
      // the other one. 'cancelled' is silent on that side.
      _sttCancelForMicHandoff();
      // Deliberately NOT clearing _nativeRecordingActive here. The page
      // outlives this handler (it also runs on minimize) and still owns its
      // recording; clearing the flag without stopping the recorder would let
      // the next dictation talk to a mic that is already taken.
      // Notify the page running inside dialog1 that the dialog just
      // closed — useful for the language page to pause TTS, stop a
      // running clip, or persist state before the user comes back.
      // Dispatched as a CustomEvent on `window`; pages listen with
      //   window.addEventListener('cupitorDialog1Closed', ...)
      // The controller stays alive across opens, so a fresh listener
      // isn't required after every show.
      try {
        dialogController?.runJavaScript(
          "window.dispatchEvent(new CustomEvent('cupitorDialog1Closed'));",
        );
      } catch (_) { /* page may not have finished loading — ignore */ }
    });
  }

  Widget _buildDialog1Content(BuildContext ctx, double screenWidth, double screenHeight) {
    // Fullscreen gives the page the toolbar's row too; the toolbar comes back
    // with the exit button laid over the page (see _showDialog1).
    final fullscreen = _dialog1FullscreenNotifier.value;
    return Container(
      width: screenWidth,
      height: screenHeight,
      child: Column(
        children: [
          if (!fullscreen) Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Theme(
              // Compact the icon row so the title bar takes less vertical space.
              // Default IconButton is 48×48 (tap target) — drop padding + use
              // shrinkWrap to land around ~32×32 per button.
              data: Theme.of(ctx).copyWith(
                iconButtonTheme: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    padding: const EdgeInsets.all(4),
                    minimumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              child: Row(
                // Order: Close, CC, AI on the LEFT — Mic, Fullscreen, Minimize,
                // Close on the RIGHT — Spacer in the middle. This keeps the
                // left cluster clear of the Android camera notch on the right
                // edge while preserving access to the secondary close.
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
                IconButton(
                  tooltip: 'Download YouTube subtitles (translate, send to lookup)',
                  icon: const Icon(Icons.closed_caption_outlined, size: 20),
                  onPressed: () => _startYouTubeSubtitleDownload(ctx),
                ),
                IconButton(
                  tooltip: 'Ask AI about this word (share)',
                  icon: const Icon(Icons.auto_awesome, size: 20),
                  onPressed: _shareSearchTextToAi,
                ),
                const Spacer(),
                GestureDetector(
                  // Long-press = enter continuous-listen mode (until next tap
                  // to stop). Tap = original one-shot voice input. Mirrors the
                  // main app bar's mic at the bottom of this file.
                  //
                  // Android-only: the inner IconButton must NOT set tooltip:
                  // Flutter's Tooltip claims the touch long-press to show
                  // itself and, being the inner gesture detector, wins the
                  // arena over this outer onLongPress.
                  onLongPress: () {
                    if (Platform.isAndroid && !_isListening) {
                      HapticFeedback.mediumImpact();
                    }
                    _startContinuousVoiceCapture();
                  },
                  child: ValueListenableBuilder<bool>(
                    // The mic state changes async inside _speech callbacks, so
                    // the outer State's setState() doesn't repaint the dialog
                    // route — listen to the mirrored notifier instead.
                    valueListenable: _isListeningNotifier,
                    builder: (_, listening, __) => IconButton(
                      tooltip: Platform.isAndroid
                          ? null
                          : (listening
                              ? (_continuousVoiceActive ? 'Stop continuous capture' : 'Stop listening')
                              : 'Voice input (long-press for continuous)'),
                      icon: Icon(
                        listening ? Icons.mic : Icons.mic_none,
                        color: listening
                            ? (_continuousVoiceActive ? Colors.red : Colors.redAccent)
                            : null,
                      ),
                      onPressed: () {
                        if (_continuousVoiceActive) {
                          _stopContinuousVoiceCapture();
                        } else {
                          _toggleVoiceInput();
                        }
                      },
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload page (bypass cache)',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () async {
                    // Clear HTTP cache so we actually pick up server changes —
                    // bare reload() honours cache headers and was returning
                    // stale pages. We stay on the same dialog route (no pop)
                    // and just rerun loadRequest against the current language URL.
                    final ctrl = dialogController;
                    if (ctrl == null) return;
                    try { await ctrl.clearCache(); } catch (_) {}
                    await ctrl.loadRequest(Uri.parse(getUrlForLanguage(_selectedLanguage)));
                  },
                ),
                IconButton(
                  tooltip: 'Minimize',
                  icon: const Icon(Icons.minimize, size: 20),
                  onPressed: () {
                    setState(() {
                      _dialog1Minimized = true;
                      _dialog1EverMinimized = true; // Mark as ever minimized
                    });
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    // Clear minimized state when manually closing
                    setState(() => _dialog1Minimized = false);
                    Navigator.of(ctx).pop();
                    _bumpMinimizedVersion();
                  },
                ),
              ],
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<String?>(
              valueListenable: _dialogErrorNotifier,
              builder: (_, error, __) => error != null
                  ? _errorView(error, () {
                      _dialogErrorNotifier.value = null;
                      if (dialogController == null) {
                        // A renderer death clears this. Behind a `?.` the
                        // button would silently do nothing and leave an empty
                        // panel, so rebuild instead of no-opping.
                        _openDialogWithWebview('');
                      } else {
                        dialogController!.loadRequest(
                            Uri.parse(getUrlForLanguage(_selectedLanguage)));
                      }
                    })
                  : ValueListenableBuilder<bool>(
                      valueListenable: einkMode,
                      builder: (_, eink, child) => ColorFiltered(
                        colorFilter: eink ? einkColorFilter : identityColorFilter,
                        child: child,
                      ),
                      // Null-safe rather than `!`: a renderer death drops this
                      // controller while the dialog is still on screen, and the
                      // force-unwrap turned that recovery into a crash.
                      child: dialogController == null
                          ? const SizedBox.shrink()
                          : pageCursor(WebViewWidget(controller: dialogController!)),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _speechLocale() => speechBcp47(_selectedLanguage) ?? 'en-US';

  Future<bool> _ensureSpeechInit() => SpeechHub.ensureInitialized();

  /// Routes an engine status to whichever feature currently holds the mic.
  void _onSpeechStatus(String status) {
    // 'done' ONLY, for every consumer. 'notListening' is emitted at
    // end-of-speech and reaches us *before* the engine's final result:
    // acting on it truncates a transcript to its last partial, and — for the
    // restart loop — schedules a fresh listen() that resets the plugin's
    // final-result timer and destroys the utterance outright. 'done' is
    // always delivered eventually: the plugin gates it behind the final
    // result, promotes it when the final arrives late, and emits it
    // unconditionally when nothing was heard at all.
    if (status != 'done') return;
    if (_sttSession.isBusy) {
      _sttApply(_sttSession.engineDone());
      return;
    }
    if (_continuousVoiceActive) {
      if (mounted) _restartContinuousListen();
      return;
    }
    _onVoiceInputStatusDone();
  }

  /// Routes an engine error the same way. Note the predicate is `isBusy`, not
  /// "listening": an error raised while we are still opening the mic belongs
  /// to the dictation session too, and must not fall through to the one-shot
  /// handler and pop a native dialog over the WebView.
  void _onSpeechError(stt.SpeechRecognitionError error) {
    if (_sttSession.isBusy) {
      final outcome = mapSpeechError(error.errorMsg);
      _sttApply(outcome.silent
          ? _sttSession.engineDoneConfirmed()
          : _sttSession.engineError(outcome.error!));
      return;
    }
    if (_continuousVoiceActive) {
      debugPrint('Continuous speech error: ${error.errorMsg}');
      if (mounted) _restartContinuousListen();
      return;
    }
    _onVoiceInputError(error);
  }

  /// Another feature took the microphone — the tag-capture sheet's mask mic,
  /// typically. No further events are coming, so settle whatever was open and
  /// put the UI back rather than leaving a lit mic icon wired to nothing.
  void _onSpeechLost() {
    if (_sttSession.isBusy) {
      _sttApply(_sttSession.cancel());
      return;
    }
    if (_continuousVoiceActive) {
      // Quietly: the transcript belongs to a capture the user did not end,
      // and _stopContinuousVoiceCapture would pop a dialog over whatever
      // just claimed the mic.
      _continuousVoiceActive = false;
    }
    if (mounted && _isListening) setState(() => _isListening = false);
    _isListeningNotifier.value = false;
  }

  /// The one-shot listen ended. Was `_toggleVoiceInput`'s onStatus closure.
  void _onVoiceInputStatusDone() {
    if (!mounted || !_isListening) return;
    setState(() => _isListening = false);
    _isListeningNotifier.value = false;
    // Resume normal timer behavior when voice input stops
    if (_showAppBar && _autoHideAppBar) {
      _showAppBarWithTimer();
    }
    if (_voiceLastWords.isNotEmpty) {
      _openDialogWithWebview(_voiceLastWords);
      _voiceLastWords = '';
    }
  }

  /// The one-shot listen failed. Was `_toggleVoiceInput`'s onError closure.
  void _onVoiceInputError(stt.SpeechRecognitionError error) {
    debugPrint('Speech error: $error');
    // Don't leave a failed attempt's words behind for a later 'done' to
    // dispatch.
    _voiceLastWords = '';
    // Guard on _isListening so a stray error arriving after some *other*
    // feature's session cannot pop the fallback dialog out of nowhere.
    if (!mounted || !_isListening) return;
    setState(() => _isListening = false);
    _isListeningNotifier.value = false;
    // Resume normal timer behavior on error
    if (_showAppBar && _autoHideAppBar) {
      _showAppBarWithTimer();
    }
    // Fallback to text input if speech fails
    _showVoiceInputFallback();
  }

  Future<void> _toggleVoiceInput() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
            _isListeningNotifier.value = false;
      // Resume normal app bar timer behavior when voice input stops
      if (_showAppBar && _autoHideAppBar) {
        _showAppBarWithTimer();
      }
      return;
    }
    // Dialog1's own mic button sits next to the webapp's, so a dictation may
    // be in flight. End it properly instead of stealing the recognizer out
    // from under it — otherwise its rid settles with the pre-hijack text and
    // this listen's words go to the wrong place.
    await _sttCancelForMicHandoff();
    // Show app bar when starting voice input
    _showAppBarWithTimer();
    try {
      _voiceLastWords = '';
      final available = await _ensureSpeechInit();
      if (!available) {
        _showVoiceInputFallback();
        return;
      }
      setState(() => _isListening = true);
      _isListeningNotifier.value = true;
      SpeechHub.acquire(_speechHubListener);
      await _speech.listen(
        localeId: _speechLocale(),
        onResult: (result) {
          _voiceLastWords = result.recognizedWords;
          if (result.finalResult && _voiceLastWords.isNotEmpty) {
            _speech.stop();
            setState(() => _isListening = false);
            _isListeningNotifier.value = false;
            // Resume normal timer behavior when voice input completes
            if (_showAppBar && _autoHideAppBar) {
              _showAppBarWithTimer();
            }
            if (mounted) {
              _openDialogWithWebview(_voiceLastWords);
              _voiceLastWords = '';  // prevent double dispatch from onStatus
            }
          }
        },
        listenFor: const Duration(seconds: 10),
      );
    } catch (e) {
      debugPrint('Speech init error: $e');
      if (mounted) {
        setState(() => _isListening = false);
            _isListeningNotifier.value = false;
        // Resume normal timer behavior on error
        if (_showAppBar && _autoHideAppBar) {
          _showAppBarWithTimer();
        }
      }
    }
  }

  /// Starts the long-press dictation mode. Accumulates partial+final results
  /// into `_continuousTranscript` and auto-restarts the recognizer each time
  /// the underlying engine ends an utterance, until the user taps the mic to
  /// stop (or 5 minutes elapse as a safety net).
  Future<void> _startContinuousVoiceCapture() async {
    if (_continuousVoiceActive) return;
    // End a webapp dictation cleanly before taking the recognizer — while one
    // is in flight it owns the status routing, so the restart loop below
    // would never fire.
    await _sttCancelForMicHandoff();
    // If a normal (one-shot) listen is in progress, cancel it first.
    if (_isListening) {
      try { await _speech.stop(); } catch (_) {}
    }
    _continuousTranscript.clear();
    _continuousPartial = '';
    _continuousVoiceActive = true;
    setState(() => _isListening = true);
    _isListeningNotifier.value = true;
    _showAppBarWithTimer();
    final started = await _initContinuousListen();
    if (!started) {
      _continuousVoiceActive = false;
      setState(() => _isListening = false);
      _isListeningNotifier.value = false;
      _showVoiceInputFallback();
    }
  }

  Future<bool> _initContinuousListen() async {
    try {
      // The plugin ends each utterance on its own; in continuous mode we just
      // restart listening as long as the user still wants us listening. That
      // restart now happens in _onSpeechStatus / _onSpeechError, which are
      // installed once by _ensureSpeechInit.
      final ok = await _ensureSpeechInit();
      if (!ok) return false;
      SpeechHub.acquire(_speechHubListener);
      await _speech.listen(
        localeId: _speechLocale(),
        partialResults: true,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 30),
        onResult: (result) {
          final words = result.recognizedWords;
          if (result.finalResult) {
            if (words.trim().isNotEmpty) {
              if (_continuousTranscript.isNotEmpty) _continuousTranscript.write(' ');
              _continuousTranscript.write(words.trim());
            }
            _continuousPartial = '';
          } else {
            _continuousPartial = words;
          }
        },
      );
      return true;
    } catch (e) {
      debugPrint('Continuous speech init failed: $e');
      return false;
    }
  }

  void _restartContinuousListen() {
    if (!_continuousVoiceActive) return;
    // Tiny delay so the plugin's previous session is fully torn down before
    // we kick off a new one. Without it, listen() occasionally throws.
    Future.delayed(const Duration(milliseconds: 200), () async {
      if (!_continuousVoiceActive) return;
      try {
        SpeechHub.acquire(_speechHubListener);
        await _speech.listen(
          localeId: _speechLocale(),
          partialResults: true,
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 30),
          onResult: (result) {
            final words = result.recognizedWords;
            if (result.finalResult) {
              if (words.trim().isNotEmpty) {
                if (_continuousTranscript.isNotEmpty) _continuousTranscript.write(' ');
                _continuousTranscript.write(words.trim());
              }
              _continuousPartial = '';
            } else {
              _continuousPartial = words;
            }
          },
        );
      } catch (e) {
        debugPrint('Continuous restart failed: $e');
      }
    });
  }

  Future<void> _stopContinuousVoiceCapture() async {
    if (!_continuousVoiceActive) return;
    _continuousVoiceActive = false;
    try { await _speech.stop(); } catch (_) {}
    SpeechHub.release(_speechHubListener);
    if (mounted) setState(() => _isListening = false);
    if (mounted) _isListeningNotifier.value = false;
    _flushContinuousTranscript();
  }

  /// Drains the accumulated long-press transcript and shows it. Split out so
  /// the resume path can surface a capture that was interrupted by the app
  /// being backgrounded.
  void _flushContinuousTranscript() {
    // Append any trailing partial that hadn't promoted to a final result yet.
    if (_continuousPartial.trim().isNotEmpty) {
      if (_continuousTranscript.isNotEmpty) _continuousTranscript.write(' ');
      _continuousTranscript.write(_continuousPartial.trim());
    }
    final transcript = _continuousTranscript.toString().trim();
    _continuousPartial = '';
    _continuousTranscript.clear();
    if (!mounted) return;
    if (transcript.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No speech captured'), duration: Duration(seconds: 2)),
      );
      return;
    }
    _showTranscriptDialog(transcript);
  }

  /// Opens a dialog that hosts the captured text in a WebView, with the
  /// same `clickable-word` wrapping (and CaptionHandler bridge) the main
  /// page uses — so tapping a word triggers the usual lookup flow.
  Future<void> _showTranscriptDialog(String transcript) async {
    final escaped = _htmlEscape(transcript);
    final utilsJs = await rootBundle.loadString('assets/js/utils.js');
    final html = '''
<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body { font-family: -apple-system, system-ui, sans-serif; font-size: 17px;
         line-height: 1.6; padding: 16px; color: #222; }
  .clickable-word { cursor: pointer; border-bottom: 1px dotted #888; }
  .clickable-word:active { background: #ffe082; }
</style>
</head><body><div id="transcript">$escaped</div>
<script>$utilsJs</script>
</body></html>
''';
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dctx) {
        late final WebViewController ctrl;
        ctrl = WebViewController()
          ..configureForMac()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setUserAgent(_userAgent)
          ..addJavaScriptChannel('CaptionHandler', onMessageReceived: (msg) {
            // Tap a word → main lookup flow.
            _openDialogWithWebview(msg.message.toString().replaceAll('"', ''));
          })
          ..loadHtmlString(html);
        final screenW = MediaQuery.of(dctx).size.width;
        final screenH = MediaQuery.of(dctx).size.height;
        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: screenW * 0.02, vertical: 24),
          child: SizedBox(
            width: screenW * 0.96,
            height: screenH * 0.85,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.mic, size: 18, color: Colors.red),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('Captured speech', style: TextStyle(fontWeight: FontWeight.w600))),
                      IconButton(
                        tooltip: 'Copy text',
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: transcript));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: 'Close',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(dctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: pageCursor(WebViewWidget(controller: ctrl))),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Minimal HTML escape — only needs to cover the characters that can
  /// terminate or escape attribute / element context.
  String _htmlEscape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  void _showVoiceInputFallback() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Enter word'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: 'Type a word...', border: OutlineInputBorder()),
          onSubmitted: (text) {
            Navigator.of(ctx).pop();
            if (text.trim().isNotEmpty) _openDialogWithWebview(text.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (ctrl.text.trim().isNotEmpty) _openDialogWithWebview(ctrl.text.trim());
            },
            child: Text('Look up'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Headset / Bluetooth media-key bridge for dialog1
  //
  // Native MainActivity owns a MediaSessionCompat that, while active, claims
  // headset play/pause/next/prev. Each press is forwarded here over a
  // MethodChannel; we synthesise a `cupitorMediaKey` CustomEvent and inject it
  // into dialog1's WebView. The language page can listen for it directly to
  // run custom behavior — replay current item, jump to previous video in the
  // record queue, etc. Default behaviors (forward to YT IFrame API) are wired
  // by the small shim injected on every page load.
  // -------------------------------------------------------------------------
  void _setMediaSessionActive(bool active) {
    if (!Platform.isAndroid) return;
    if (active == _mediaSessionActive) return;
    _mediaSessionActive = active;
    _mediaKeysChannel.invokeMethod<void>('setActive', {'active': active});
  }

  void _setMediaSessionState({required bool playing, String? title, String? artist}) {
    if (!Platform.isAndroid) return;
    _mediaKeysChannel.invokeMethod<void>('setState', {
      'playing': playing,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
    });
  }

  void _dispatchMediaKeyToDialog1(String key) {
    final ctrl = dialogController;
    if (ctrl == null) return;
    final escaped = jsonEncode(key);
    ctrl.runJavaScript(
      "window.dispatchEvent(new CustomEvent('cupitorMediaKey', { detail: { key: $escaped } }));"
    );
  }

  /// Page → Dart: page reports its playback state so we can keep the system
  /// MediaSession (and therefore lockscreen / car / BT) in sync with what's
  /// actually playing.
  void _handleMediaStateBridge(JavaScriptMessage msg) {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final playing = req['playing'] as bool? ?? false;
    final title = req['title'] as String?;
    final artist = req['artist'] as String?;
    _setMediaSessionState(playing: playing, title: title, artist: artist);
  }

  // ---- AudioBridge: persist manual-entry recordings on disk ----
  //
  // The dialog1 WebView can't write to the device file system itself, so the
  // editor's recorder pipes audio bytes (base64 data URL) through this bridge.
  // We save to <app_documents>/manual_audio/<id>.<ext> and hand back a
  // `file://...` URL. The reverse — loading audio for playback — returns the
  // bytes as a base64 data URL so JS can play them via `new Audio(...)` or
  // `URL.createObjectURL(blob)` without needing direct file:// access (which
  // Android WebView blocks for security).
  //
  // Wire format (JS → Flutter), JSON envelope:
  //   {op:'save',   rid, id, dataUrl}            → __cupAudio('save',   rid, fileUrl|null, err|null)
  //   {op:'load',   rid, url}                    → __cupAudio('load',   rid, dataUrl|null, err|null)
  //   {op:'delete', rid, url}                    → __cupAudio('delete', rid, true|false,   err|null)
  //
  // `rid` is a JS-supplied request id used only to resolve the corresponding
  // Promise on the JS side — the Dart side echoes it back unchanged.
  Future<Directory> _manualAudioDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/manual_audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeFileId(String id) {
    // Restrict to filename-safe characters; collapses anything weird from JS.
    return id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  }

  // ---- Background music: files the user picked from the device ----
  //
  // Kept in their own directory, with their own resolver, so neither these ops
  // nor the manual_audio ops above can reach the other's files.
  //
  // The WebView can't be handed a file:// URL — the page is loaded over https
  // and cannot reference one — so the bytes reach it through the native
  // LocalMedia interception instead. These ops only ever deal in file:// URLs
  // and names; building the served URL is the page's job.
  Future<Directory> _musicDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/music');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Whether this device can serve local music to the WebView. The music ops
  /// AWAIT this rather than reading a flag, so a panel opened before the
  /// native attach has answered waits for the answer instead of being told
  /// the device is unsupported. Null until the first page load.
  Future<bool>? _localMediaAttach;

  void _attachLocalMedia() {
    if (!Platform.isAndroid) return;
    _localMediaAttach = _attachLocalMediaOnce();
  }

  Future<bool> _attachLocalMediaOnce() async {
    try {
      final dir = await _musicDir();
      // Flutter builds the platform view lazily, so early attempts can land
      // before any WebView exists to attach to — the same reason
      // [_installRenderGuard] retries. Wrapping nothing is not success.
      for (var attempt = 0; attempt < 12; attempt++) {
        final res = await _permsChannel.invokeMethod<String>(
          'attachLocalMedia', {'dir': dir.path},
        );
        if (res == null || res == 'unsupported') return false;
        if (!res.startsWith('no-webview')) return true;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Where a picked file should be copied, and whether a copy is needed at
  /// all. Returns `(file, true)` when a file of the same name AND size is
  /// already there — the same song picked again — so the page's library sees
  /// one track rather than a growing set of copies. A name that is taken by a
  /// different file gets a counter rather than overwriting it.
  Future<(File, bool)> _musicDestFor(
      Directory dir, String original, int srcLength) async {
    final (stem, ext) = musicSplitExt(musicSafeFileName(original));
    var candidate = File('${dir.path}/$stem$ext');
    var n = 2;
    while (await candidate.exists()) {
      if (await candidate.length() == srcLength) return (candidate, true);
      candidate = File('${dir.path}/$stem ($n)$ext');
      n++;
    }
    return (candidate, false);
  }

  /// Map a `file://` URL back to a file inside the music directory, refusing
  /// anything outside it — including a path that only leaves via `..`.
  Future<File?> _resolveMusicUrl(String url) async {
    final dir = await _musicDir();
    final path = filePathInsideDir(url, dir.path);
    return path == null ? null : File(path);
  }

  String _extFromDataUrl(String dataUrl) {
    // data:audio/webm;codecs=opus;base64,XXXX → 'webm'.
    final m = RegExp(r'^data:audio/([a-zA-Z0-9.+-]+)').firstMatch(dataUrl);
    final raw = (m?.group(1) ?? 'webm').toLowerCase();
    // Strip codec descriptors after a `+` if any, keep core type.
    return raw.split('+').first;
  }

  /// Build the `file://...` URL we hand back to JS. We use a `cupitor-file://`
  /// prefix in addition to `file://` callers, but the canonical form is plain
  /// `file://<absolute path>`, since the user asked for "url like file://...".
  String _fileUrlForPath(String path) => 'file://$path';

  /// Map a `file://...` URL the WebView gave us back to an on-disk path,
  /// confined to our manual_audio directory (defensive — refuse paths outside
  /// it so a malicious page can't read random files).
  Future<File?> _resolveAudioUrl(String url) async {
    final dir = await _manualAudioDir();
    // Collapses `..` before checking, so a URL that only leaves the
    // directory through a dot segment is refused too.
    final path = filePathInsideDir(url, dir.path);
    return path == null ? null : File(path);
  }

  void _audioReply(String op, String rid, String? result, String? err) {
    // Stringify safely. result/err are short strings or JSON-encodable.
    final payload = jsonEncode({
      'op': op, 'rid': rid,
      if (result != null) 'result': result,
      if (err != null) 'error': err,
    });
    try {
      dialogController?.runJavaScript(
        'window.__cupAudio && window.__cupAudio($payload);',
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  // SpeechBridge — dictation for the webapp's manual-card editor.
  // Protocol: docs/speech-bridge-spec.md. The rid routing lives in
  // SpeechSession (lib/speech_session.dart); everything here is I/O.
  // ---------------------------------------------------------------------

  /// How long a `start` may sit unconfirmed before we call it a busy mic.
  /// `listen()` returns normally when the platform refuses the recognizer —
  /// no throw, no timers, no callback ever — so a deadline is the only way
  /// to notice.
  static const _kSttStartDeadline = Duration(seconds: 2);

  /// How long the engine may read as stopped before we settle without a
  /// `done`. Must exceed the plugin's own 2 s final-result timer, otherwise
  /// this fires in the gap between end-of-speech and the final result and
  /// truncates the transcript on every normal auto-stop.
  static const _kSttQuietSettle = Duration(seconds: 4);

  static const _kSttListenFor = Duration(seconds: 30);

  /// Grace for a trailing error after an empty `done`. The plugin delivers
  /// `doneNoResult` as `done` ungated, and it arrives *before* the real error.
  static const _kSttDoneDebounce = Duration(milliseconds: 400);

  void _speechReply(String rid, {String? result, String? error, String? partial}) {
    final ctrl = dialogController;
    if (ctrl == null) return;
    final payload = jsonEncode({
      'rid': rid,
      if (result != null) 'result': result,
      if (error != null) 'error': error,
      if (partial != null) 'partial': partial,
    });
    try {
      ctrl
          .runJavaScript('window.__cupSpeech && window.__cupSpeech($payload);')
          .catchError((_) {/* dialog1 not loaded yet */});
    } catch (_) {}
  }

  Future<void> _handleSpeechBridge(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final op = (req['op'] as String?) ?? '';
    final rid = (req['rid'] as String?) ?? '';
    switch (op) {
      case 'start':
        await _sttApply(_sttSession.start(rid, req['locale'] as String?));
      case 'stop':
        // Note: stop/cancel act on the in-flight listen and settle the START
        // rid. Their own rid has no pending entry on the page.
        await _sttApply(_sttSession.stop());
      case 'cancel':
        await _sttApply(_sttSession.cancel());
    }
  }

  /// Performs whatever the session decided.
  Future<void> _sttApply(SpeechAction action) async {
    switch (action) {
      case SpeechNoOp():
        return;
      case SpeechListen(:final rid, :final locale):
        await _sttBeginListen(rid, locale);
      case SpeechDefer():
        // Never re-arm: the watchdog can ask to defer every 250 ms, which is
        // faster than the debounce fires. Re-arming would reset it forever
        // and the rid would never settle.
        if (_sttDoneDebounce?.isActive ?? false) return;
        _sttDoneDebounce = Timer(_kSttDoneDebounce, () {
          _sttApply(_sttSession.engineDoneConfirmed());
        });
      case SpeechReply(:final rid, :final result, :final error, :final partial):
        if (action.settlesSession) {
          // Let go of the mic on every settling path, not just the ones the
          // engine drove. A watchdog or abort settle can leave the recognizer
          // running with nobody owning it. Note this is keyed on
          // settlesSession, not terminal: a BUSY rejection must leave the
          // in-flight session and its timers completely alone.
          _sttStopTimers();
          try { await _speech.cancel(); } catch (_) {}
        }
        _speechReply(rid, result: result, error: error, partial: partial);
    }
  }

  Future<void> _sttBeginListen(String rid, String? locale) async {
    // §7 — free the mic. The native recorder wins: refusing is friendlier
    // than binning a clip the user is still recording.
    if (_nativeRecordingActive) {
      await _sttApply(_sttSession.abort(rid, 'mic-busy'));
      return;
    }
    // Releases any lingering session on the shared recognizer, clears the
    // long-press restart loop so it can't steal the mic back, and waits out
    // the 500 ms AudioRecord settle the OS needs.
    await _releaseMicFromSpeechToText();

    if (!await _ensureMicPermission()) {
      await _sttApply(_sttSession.abort(rid, 'permission-denied'));
      return;
    }
    if (!await _ensureSpeechInit()) {
      await _sttApply(_sttSession.abort(rid, 'speech-unavailable'));
      return;
    }
    // A stop/cancel may have landed during the awaits above and already
    // settled this rid. Keep this check adjacent to listen() with no await
    // between them, so check-and-listen is atomic on the event loop.
    if (_sttSession.startRid != rid) return;
    // From here on the engine's events are ours, not the outgoing session's.
    _sttSession.listenIssued(rid);
    SpeechHub.acquire(_speechHubListener);
    try {
      await _speech.listen(
        localeId: speechBcp47(locale),
        listenFor: _kSttListenFor,
        pauseFor: const Duration(seconds: 3),
        listenOptions: stt.SpeechListenOptions(partialResults: true),
        onResult: (r) => _sttApply(
          _sttSession.result(r.recognizedWords, isFinal: r.finalResult),
        ),
      );
    } catch (e) {
      debugPrint('SpeechBridge listen failed: $e');
      // Not abort(): listen() assigns its result listener before it awaits,
      // so a partial may already have moved us out of `starting`, and abort
      // would no-op there and strand the rid with no watchdog to rescue it.
      if (_sttSession.startRid == rid) {
        await _sttApply(_sttSession.engineError('speech-unavailable'));
      }
      return;
    }
    // A stop/cancel that landed *during* listen() can't be undone by the
    // guard above — the recognizer is already coming up owned by nobody.
    if (_sttSession.startRid != rid) {
      try { await _speech.cancel(); } catch (_) {}
      return;
    }
    // Deliberately not marking the session live here: the platform can refuse
    // silently, so we wait for evidence (isListening, or a result).
    _sttStartWatchdog(rid);
  }

  void _sttStartWatchdog(String rid) {
    _sttWatchdog?.cancel();
    _sttListenStartedAt = DateTime.now();
    _sttQuietSince = null;
    _sttWatchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_sttSession.isBusy || _sttSession.startRid != rid) {
        _sttWatchdog?.cancel();
        _sttWatchdog = null;
        return;
      }
      final now = DateTime.now();
      final since = now.difference(_sttListenStartedAt ?? now);

      if (_sttSession.phase == SpeechPhase.starting) {
        if (_speech.isListening) {
          _sttSession.listening(rid);
        } else if (since > _kSttStartDeadline) {
          // The platform took the call and did nothing — something else holds
          // the recognizer.
          _sttApply(_sttSession.abort(rid, 'mic-busy'));
        }
        return;
      }

      if (_speech.isListening) {
        _sttQuietSince = null;
      } else {
        _sttQuietSince ??= now;
        if (now.difference(_sttQuietSince!) > _kSttQuietSettle) {
          // We missed 'done' — most likely another screen won the
          // initialize() race and owns the status callback.
          _sttApply(_sttSession.engineDone());
          return;
        }
      }
      if (since > _kSttListenFor + const Duration(seconds: 5)) {
        _sttApply(_sttSession.engineDone());
      }
    });
  }

  void _sttStopTimers() {
    _sttWatchdog?.cancel();
    _sttWatchdog = null;
    _sttDoneDebounce?.cancel();
    _sttDoneDebounce = null;
  }

  /// Stops the native recorder if we believe one is running, discarding the
  /// partial clip. For teardown paths only — the page that owns the clip is
  /// already gone, so nobody is left to call `recordStop`. Unconditional on
  /// the native side, which no-ops when no recorder is open.
  void _stopNativeRecordingIfAny() {
    _nativeRecordingActive = false;
    _permsChannel.invokeMethod<void>('cancelNativeRecording').catchError((_) {});
  }

  /// Ends a dictation session because something else is claiming the mic.
  ///
  /// `_releaseMicFromSpeechToText()` cancels the recognizer, and a cancel
  /// produces no Dart callback at all once partials have been seen — so
  /// without this the page would wait on the watchdog. Answer it now instead;
  /// 'cancelled' is silent in the webapp and restores the field.
  Future<void> _setStudyFsChipEnabled(bool on) async {
    setState(() => _studyFsChipEnabled = on);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('studyFullscreenButton', on);
    if (!on && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Fullscreen button hidden — turn it back on in Tools'),
      ));
    }
  }

  /// Opens the study dialog (dialog1) filling the screen. Fullscreen lasts
  /// until the dialog is closed or minimized, which put it back to normal, so
  /// every other way of opening it is unchanged. Over a fullscreen page (a
  /// video) it opens at its normal size, so the video stays in view around it.
  void _openStudyFullscreen() {
    if (!_webFullscreen) _dialog1FullscreenNotifier.value = true;
    if (dialogController == null) {
      _openDialogWithWebview('');
    } else {
      _showDialog1();
    }
  }

  Future<void> _setVideoNoteEnabled(bool on) async {
    setState(() => _videoNoteEnabled = on);
    on ? _videoNotePoller.start() : _videoNotePoller.stop();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('videoNoteButton', on);
  }

  /// Floating video-note button: note the video's current moment, take typed
  /// or dictated text, and send it down the caption-capture path so the
  /// webapp files it as a card whose link opens the video at that moment.
  Future<void> _openVideoNote() async {
    VideoMoment? moment;
    try {
      moment = parseVideoMoment(await _controller
          .runJavaScriptReturningResult(videoMomentJs(pause: true)));
    } catch (_) {}
    if (!mounted) return;
    if (moment == null) {
      // The page may have paused something it could not report on.
      _controller.runJavaScript(kResumeNoteVideoJs).catchError((_) {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No video found on this page')),
      );
      return;
    }
    final note = await showVideoNoteDialog(
      context,
      moment: moment,
      speechLocale: _speechLocale(),
      prepareMic: () async {
        if (_nativeRecordingActive) return false;
        await _sttCancelForMicHandoff();
        await _releaseMicFromSpeechToText();
        return _ensureMicPermission();
      },
    );
    // Anything short of handing the note over goes back to watching. After a
    // send the video stays paused: dialog1 opens over it to file the card.
    void resume() {
      if (moment!.wasPlaying) {
        _controller.runJavaScript(kResumeNoteVideoJs).catchError((_) {});
      }
    }
    if (!mounted) return;
    final detail = note == null
        ? null
        : buildCaptionCaptureDetail(
            videoNoteBlock(moment, note.text, seconds: note.seconds),
            fallbackLang: _selectedLanguage,
          );
    if (detail == null) {
      resume();
      return;
    }
    try {
      await _sendCaptionCaptureToDialog1(detail);
    } catch (e) {
      resume();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send the note: $e')),
      );
    }
  }

  /// One-tap entry point for collecting sentences off a web page.
  ///
  /// The underlying mechanism is the same capture mode the tag chip arms, but
  /// reaching it meant Tag Settings → show the chip → tap the chip, behind a
  /// switch labelled for tagging. That made a working feature undiscoverable,
  /// which is exactly how it was reported. This shows the chip — so the armed
  /// state stays visible and can be turned off again — and arms the page in
  /// one action, keeping a single source of truth for the mode.
  void _armSentenceCollecting() {
    setState(() {
      _tagCaptureToggleVisible = true;
      _tagCaptureArmed = true;
    });
    _controller.runJavaScript(
      'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(true);',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tap sentences to collect them, then Send in the page'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  Future<void> _sttCancelForMicHandoff() async {
    if (!_sttSession.isBusy) return;
    await _sttApply(_sttSession.cancel());
    // Give the recognizer the same beat every other cancel→listen path in
    // this file allows. Without it the caller's own listen() can be refused
    // and — since a refusal arms nothing and never calls back — leave that
    // feature wedged with its mic icon lit. Only paid when a dictation was
    // actually running.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  Future<void> _handleAudioBridge(JavaScriptMessage msg) async {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final op = (req['op'] as String?) ?? '';
    final rid = (req['rid'] as String?) ?? '';
    try {
      if (op == 'save') {
        final id = _safeFileId((req['id'] as String?) ?? '');
        final dataUrl = (req['dataUrl'] as String?) ?? '';
        final comma = dataUrl.indexOf(',');
        if (id.isEmpty || !dataUrl.startsWith('data:') || comma < 0) {
          _audioReply('save', rid, null, 'bad-payload');
          return;
        }
        final ext = _extFromDataUrl(dataUrl);
        final bytes = base64Decode(dataUrl.substring(comma + 1));
        final dir = await _manualAudioDir();
        final f = File('${dir.path}/$id.$ext');
        await f.writeAsBytes(bytes, flush: true);
        _audioReply('save', rid, _fileUrlForPath(f.path), null);
      } else if (op == 'load') {
        final url = (req['url'] as String?) ?? '';
        final f = await _resolveAudioUrl(url);
        if (f == null || !await f.exists()) {
          _audioReply('load', rid, null, 'not-found');
          return;
        }
        final bytes = await f.readAsBytes();
        final ext = f.path.split('.').last.toLowerCase();
        final mime = ext == 'mp4' ? 'audio/mp4'
                   : ext == 'm4a' ? 'audio/mp4'
                   : ext == 'ogg' ? 'audio/ogg'
                   : ext == 'wav' ? 'audio/wav'
                   : ext == 'mp3' ? 'audio/mpeg'
                   : 'audio/webm';
        final dataUrl = 'data:$mime;base64,${base64Encode(bytes)}';
        _audioReply('load', rid, dataUrl, null);
      } else if (op == 'delete') {
        final url = (req['url'] as String?) ?? '';
        final f = await _resolveAudioUrl(url);
        if (f != null && await f.exists()) await f.delete();
        _audioReply('delete', rid, 'ok', null);
      } else if (op == 'musicPick' || op == 'musicList' || op == 'musicDelete') {
        // One gate for all three: the page hides its device controls on this
        // error, so it has to come back from the call it makes first.
        final ready = await (_localMediaAttach ?? Future<bool>.value(false));
        if (!ready) {
          _audioReply(op, rid, null, 'unsupported');
          return;
        }
        if (op == 'musicPick') {
          final picked = await FilePicker.platform.pickFiles(
            type: FileType.audio,
            allowMultiple: true,
          );
          final dir = await _musicDir();
          final out = <Map<String, dynamic>>[];
          var failed = 0;
          for (final f in picked?.files ?? const <PlatformFile>[]) {
            final src = f.path;
            if (src == null) { failed++; continue; }
            try {
              final srcFile = File(src);
              final (dest, reused) =
                  await _musicDestFor(dir, f.name, await srcFile.length());
              // Copy rather than reference: the picker hands back a path in
              // a cache directory the system is free to reclaim.
              if (!reused) await srcFile.copy(dest.path);
              out.add({
                'url': _fileUrlForPath(dest.path),
                // The user's own name for the file, not the sanitised copy.
                'name': musicDisplayName(f.name),
              });
            } catch (_) {
              // Reported by count rather than swallowed: a picker cache the
              // system already reclaimed, or a full disk, would otherwise look
              // exactly like the user cancelling.
              failed++;
            }
          }
          _audioReply(op, rid, jsonEncode({'picked': out, 'failed': failed}), null);
        } else if (op == 'musicList') {
          final dir = await _musicDir();
          final out = <Map<String, dynamic>>[];
          for (final e in dir.listSync()) {
            if (e is! File) continue;
            out.add({
              'url': _fileUrlForPath(e.path),
              'name': musicDisplayName(e.path),
              'size': await e.length(),
            });
          }
          _audioReply(op, rid, jsonEncode(out), null);
        } else {
          final f = await _resolveMusicUrl((req['url'] as String?) ?? '');
          if (f != null && await f.exists()) await f.delete();
          _audioReply(op, rid, 'ok', null);
        }
      } else if (op == 'ensureMicPerm') {
        // Pre-flight for JS — let it know whether the Android `RECORD_AUDIO`
        // grant is in place (asking the user if not) BEFORE it calls
        // `navigator.mediaDevices.getUserMedia`. Without this, the first
        // tap-Record after install hits getUserMedia → silent rejection →
        // confusing "permission denied" alert, with no OS prompt ever
        // shown.
        //
        // ALSO release the mic from `speech_to_text` here. STT and the
        // WebView's `getUserMedia` both want to open `AudioRecord`; only
        // one can hold the source at a time. If STT is running (long-press
        // continuous capture left active) getUserMedia rejects with
        // `NotReadableError: Could not start audio source` until STT lets
        // go. Stopping it here is the right time — JS is about to record.
        await _sttCancelForMicHandoff();
        await _releaseMicFromSpeechToText();
        final ok = await _ensureMicPermission();
        _audioReply('ensureMicPerm', rid, ok ? 'granted' : 'denied', null);
      } else if (op == 'recordStart') {
        // Native recording path: JS hands us an id, we open MediaRecorder
        // and write to <docs>/manual_audio/<id>.<ext> directly. Bypasses
        // the WebView's getUserMedia entirely — same AudioRecord plumbing
        // used by speech_to_text and any native voice recorder. Released
        // by `recordStop` (keep the file) or `recordCancel` (delete it).
        //
        // The native side picks the container: OPUS/OGG on API 29+, AAC/
        // M4A below. We hand over just the path stem and use whatever
        // extension the recorder actually wrote.
        final id = _safeFileId((req['id'] as String?) ?? '');
        if (id.isEmpty) { _audioReply('recordStart', rid, null, 'bad-id'); return; }
        await _sttCancelForMicHandoff();
        await _releaseMicFromSpeechToText();
        final permOk = await _ensureMicPermission();
        if (!permOk) { _audioReply('recordStart', rid, null, 'permission-denied'); return; }
        final dir = await _manualAudioDir();
        final pathStem = '${dir.path}/$id';
        try {
          final actualPath = await _permsChannel.invokeMethod<String>(
            'startNativeRecording', {'pathStem': pathStem},
          );
          if (actualPath != null && actualPath.isNotEmpty) {
            _nativeRecordingActive = true;
            _audioReply('recordStart', rid, _fileUrlForPath(actualPath), null);
          } else {
            _audioReply('recordStart', rid, null, 'start-failed');
          }
        } on PlatformException catch (e) {
          _audioReply('recordStart', rid, null, '${e.code}: ${e.message ?? ''}');
        }
      } else if (op == 'recordStop') {
        _nativeRecordingActive = false;
        try {
          final path = await _permsChannel.invokeMethod<String>('stopNativeRecording');
          if (path == null) {
            _audioReply('recordStop', rid, null, 'no-recording');
          } else {
            _audioReply('recordStop', rid, _fileUrlForPath(path), null);
          }
        } on PlatformException catch (e) {
          _audioReply('recordStop', rid, null, '${e.code}: ${e.message ?? ''}');
        }
      } else if (op == 'recordCancel') {
        _nativeRecordingActive = false;
        try {
          await _permsChannel.invokeMethod<void>('cancelNativeRecording');
          _audioReply('recordCancel', rid, 'ok', null);
        } on PlatformException catch (e) {
          _audioReply('recordCancel', rid, null, '${e.code}: ${e.message ?? ''}');
        }
      } else {
        _audioReply(op, rid, null, 'unknown-op');
      }
    } catch (e) {
      _audioReply(op, rid, null, e.toString());
    }
  }

  /// Default handlers + state pump injected on every dialog1 page load.
  /// - Forwards play/pause/next/previous/fast_forward/rewind to YouTube's
  ///   IFrame API (`window.ytPlayer`) when the page doesn't preventDefault.
  /// - Reflects YT player state changes to native MediaSessionCompat via the
  ///   `MediaState` channel so the lockscreen + Bluetooth display stay synced.
  static const String _mediaKeysShimJs = r'''
(function() {
  if (window.__cupitorMediaKeysInstalled) return;
  window.__cupitorMediaKeysInstalled = true;
  var bridge = window.MediaState;
  function postState() {
    if (!bridge || typeof bridge.postMessage !== 'function') return;
    var p = window.ytPlayer;
    var playing = !!window.ytPlaying;
    var title = '';
    try {
      if (p && typeof p.getVideoData === 'function') {
        var d = p.getVideoData();
        title = (d && d.title) || '';
      }
    } catch (e) {}
    if (!title) title = document.title || 'Cupitor';
    try { bridge.postMessage(JSON.stringify({ playing: playing, title: title })); } catch (e) {}
  }
  // Wrap onPlayerStateChange so we don't replace the page's handler. Any
  // future PLAYING / non-PLAYING transition pushes state.
  var origStateCb = window.onPlayerStateChange;
  window.onPlayerStateChange = function(ev) {
    try { if (typeof origStateCb === 'function') origStateCb(ev); } catch (e) {}
    setTimeout(postState, 0);
  };
  // Also poll briefly after install in case the player became ready earlier.
  var pollN = 0;
  var poll = setInterval(function() {
    pollN++;
    postState();
    if (pollN > 10) clearInterval(poll);
  }, 1000);

  // Default media-key behavior — fires only if the page didn't preventDefault.
  // The page may install its own listener via:
  //   window.addEventListener('cupitorMediaKey', function(e) { e.preventDefault(); … });
  window.addEventListener('cupitorMediaKey', function(ev) {
    if (ev.defaultPrevented) return;
    var key = ev.detail && ev.detail.key;
    var p = window.ytPlayer;
    if (!p) return;
    try {
      switch (key) {
        case 'play': p.playVideo(); break;
        case 'pause': p.pauseVideo(); break;
        case 'play_pause':
          if (window.ytPlaying) p.pauseVideo(); else p.playVideo();
          break;
        case 'fast_forward':
          if (typeof p.getCurrentTime === 'function')
            p.seekTo((p.getCurrentTime() || 0) + 10, true);
          break;
        case 'rewind':
          if (typeof p.getCurrentTime === 'function')
            p.seekTo(Math.max(0, (p.getCurrentTime() || 0) - 10), true);
          break;
        // next / previous have no sensible default for a single video —
        // leave them for the page to handle (record-queue navigation).
      }
    } catch (e) {}
    setTimeout(postState, 100);
  });
})();
''';

  // -------------------------------------------------------------------------
  // window.speechSynthesis bridge for dialog1
  //
  // Android WebView ships without the Web Speech Synthesis API — pages that
  // call `new SpeechSynthesisUtterance(...)` + `speechSynthesis.speak(...)`
  // silently no-op. macOS WKWebView has it natively, but we install the same
  // shim everywhere so utterance.onstart / .onend semantics are identical.
  //
  // The shim replaces `window.speechSynthesis` (and the Utterance constructor)
  // with objects that post a JSON envelope to the `TtsBridge` channel. Flutter
  // drives a queue against flutter_tts and pokes start/end/error callbacks
  // back into the page via runJavaScript on globals it exposed itself.
  // -------------------------------------------------------------------------
  static const String _ttsPolyfillJs = r'''
(function() {
  if (window.__cupitorTtsInstalled) return;
  window.__cupitorTtsInstalled = true;
  var bridge = window.TtsBridge;
  if (!bridge || typeof bridge.postMessage !== 'function') return;

  var pending = new Map();
  var nextId = 1;

  function post(obj) {
    try { bridge.postMessage(JSON.stringify(obj)); } catch (_) {}
  }

  function Utterance(text) {
    this.text = text == null ? '' : String(text);
    this.lang = document.documentElement.lang || '';
    this.voice = null;
    this.volume = 1.0;
    this.rate = 1.0;
    this.pitch = 1.0;
    this.onstart = null;
    this.onend = null;
    this.onerror = null;
    this.onpause = null;
    this.onresume = null;
    this.onmark = null;
    this.onboundary = null;
    var listeners = {};
    this.addEventListener = function(t, fn) { (listeners[t] = listeners[t] || []).push(fn); };
    this.removeEventListener = function(t, fn) {
      var arr = listeners[t]; if (!arr) return;
      var i = arr.indexOf(fn); if (i >= 0) arr.splice(i, 1);
    };
    this.dispatchEvent = function(ev) {
      var arr = listeners[ev.type]; if (!arr) return true;
      for (var i = 0; i < arr.length; i++) {
        try { arr[i].call(this, ev); } catch (_) {}
      }
      return true;
    };
  }
  window.SpeechSynthesisUtterance = Utterance;

  function fire(u, name, extra) {
    var handler = u['on' + name];
    if (typeof handler === 'function') {
      try { handler.call(u, Object.assign({ type: name, utterance: u }, extra || {})); } catch (_) {}
    }
    try {
      var ev = new Event(name);
      Object.assign(ev, extra || {});
      u.dispatchEvent(ev);
    } catch (_) {}
  }

  var synth = {
    paused: false,
    pending: false,
    speaking: false,
    onvoiceschanged: null,
    speak: function(u) {
      if (!u) return;
      var id = nextId++;
      pending.set(id, u);
      synth.speaking = true;
      synth.pending = pending.size > 1;
      post({
        type: 'speak',
        id: id,
        text: String(u.text || ''),
        lang: String(u.lang || ''),
        rate: Number(u.rate) || 1,
        pitch: Number(u.pitch) || 1,
        volume: Number(u.volume) || 1,
      });
    },
    cancel: function() {
      // Snapshot the utterances BEFORE clearing pending — Flutter has already
      // been told to stop, but the host's setCancelHandler only fires for the
      // active one. Without these synthetic `end` events the page's promise
      // chains (e.g. _speakWordBrowser.onend) wait the full safety timeout.
      var utterances = Array.from(pending.values());
      pending.clear();
      synth.speaking = false;
      synth.paused = false;
      synth.pending = false;
      post({ type: 'cancel' });
      utterances.forEach(function(u) {
        try { fire(u, 'end'); } catch (_) {}
      });
    },
    pause: function() { synth.paused = true; post({ type: 'pause' }); },
    resume: function() { synth.paused = false; post({ type: 'resume' }); },
    getVoices: function() { return []; },
    addEventListener: function() {},
    removeEventListener: function() {},
    dispatchEvent: function() { return true; },
  };

  window.__cupitorTtsStart = function(id) {
    var u = pending.get(id); if (!u) return;
    synth.speaking = true;
    fire(u, 'start');
  };
  window.__cupitorTtsEnd = function(id) {
    var u = pending.get(id); pending.delete(id);
    synth.pending = pending.size > 0;
    if (pending.size === 0) synth.speaking = false;
    if (!u) return;
    fire(u, 'end');
  };
  window.__cupitorTtsError = function(id, msg) {
    var u = pending.get(id); pending.delete(id);
    synth.pending = pending.size > 0;
    if (pending.size === 0) synth.speaking = false;
    if (!u) return;
    fire(u, 'error', { error: msg || 'tts-error' });
  };

  try {
    Object.defineProperty(window, 'speechSynthesis', {
      value: synth, writable: false, configurable: false,
    });
  } catch (_) {
    window.speechSynthesis = synth;
  }
})();
''';

  // Fullscreen → FullscreenChannel. 'landscape' when the fullscreen element is
  // (or holds) a wider-than-tall video, or is an iframe whose video we can't
  // see; 'other' for portrait video (Shorts) or non-video content; 'exit'
  // when leaving fullscreen. Idempotent — safe to re-run on every page-finished.
  static const String _fullscreenWatcherJs = r'''
(function() {
  if (window.__cupFullscreenWatcher) return;
  window.__cupFullscreenWatcher = true;
  function onChange() {
    var el = document.fullscreenElement || document.webkitFullscreenElement;
    var msg = 'exit';
    if (el) {
      var v = el.tagName === 'VIDEO' ? el : el.querySelector('video');
      // videoWidth is 0 until metadata loads: shape unknown, don't force it.
      if (v) msg = v.videoWidth > v.videoHeight ? 'landscape' : 'other';
      else msg = el.tagName === 'IFRAME' ? 'landscape' : 'other';
    }
    try { FullscreenChannel.postMessage(msg); } catch (e) {}
  }
  document.addEventListener('fullscreenchange', onChange, true);
  document.addEventListener('webkitfullscreenchange', onChange, true);
})();
''';

  // Long-press on a link → "Copy Link". Android dispatches a 'contextmenu'
  // event on long-press; when it lands on (or inside) an <a href> we suppress
  // the native selection menu and hand the absolute URL to Dart via the
  // LinkLongPress channel. Idempotent — safe to re-run on every page-finished.
  static const String _linkLongPressJs = r'''
(function() {
  if (window.__cupLinkLongPress) return;
  window.__cupLinkLongPress = true;
  document.addEventListener('contextmenu', function(e) {
    var t = e.target;
    var a = (t && t.closest) ? t.closest('a[href]') : null;
    if (a && a.href) {
      e.preventDefault();
      try { LinkLongPress.postMessage(a.href); } catch (_) {}
    }
  }, true);
})();
''';

  // Auto-unmute YouTube (and any HTML5 media) opened inside a dialog. Videos
  // autoplay muted under the browser's autoplay policy; the WebView already
  // sets mediaPlaybackRequiresUserGesture(false), so unmuting keeps playback
  // going rather than pausing it. The player/video mounts asynchronously, so
  // we retry on a short interval (~10s) and cover all three shapes:
  //   1. window.ytPlayer  — YT IFrame API player (our language.html)
  //   2. <video>/<audio>  — Invidious / Piped / bare YouTube page
  //   3. enablejsapi embed iframes — postMessage unMute command
  static const String _autoUnmuteYouTubeJs = r'''
(function() {
  if (window.__cupAutoUnmute) return;
  window.__cupAutoUnmute = true;
  var tries = 0;
  var timer = setInterval(function() {
    tries++;
    try {
      var p = window.ytPlayer;
      if (p && typeof p.unMute === 'function') {
        p.unMute();
        if (typeof p.setVolume === 'function') p.setVolume(100);
      }
    } catch (e) {}
    try {
      var els = document.querySelectorAll('video, audio');
      for (var i = 0; i < els.length; i++) {
        if (els[i].muted) els[i].muted = false;
      }
    } catch (e) {}
    try {
      var ifr = document.querySelectorAll(
        'iframe[src*="youtube.com/embed"], iframe[src*="youtube-nocookie.com/embed"]');
      for (var j = 0; j < ifr.length; j++) {
        try {
          ifr[j].contentWindow.postMessage(
            '{"event":"command","func":"unMute","args":[]}', '*');
        } catch (e) {}
      }
    } catch (e) {}
    if (tries > 20) clearInterval(timer);
  }, 500);
})();
''';

  /// A long-pressed link's URL arrives here from any WebView. Show a small
  /// sheet whose primary action copies the link to the clipboard.
  /// Push the current playlist state into dialog1's WebView. Called
  /// on: playlist mutations (via [PlaylistService.changes]), dialog1
  /// page finish, and any time we want the language app to refresh.
  /// Silent no-op if the controller isn't up — the JS side listens
  /// for the CustomEvent so it never has to poll.
  Future<void> _pushPlaylistsToDialog() async {
    final ctrl = dialogController;
    if (ctrl == null) return;
    try {
      final payload = await PlaylistService.buildPayloadJson();
      // Wrap the payload string so we can embed it into a JS literal
      // without worrying about internal quotes.
      final js = "window.__cupitorPlaylistsPayload = $payload;"
          "window.dispatchEvent(new CustomEvent('cupitorPlaylists', { detail: window.__cupitorPlaylistsPayload }));";
      await ctrl.runJavaScript(js);
    } catch (_) { /* dialog1 not loaded yet — safe to ignore */ }
  }

  /// Dispatch a notification-bridge CustomEvent into dialog1. Same
  /// global-then-dispatch pattern as _pushPlaylistsToDialog so a listener
  /// that attaches late can still read the current state.
  void _emitNotifEvent(String event, Map<String, Object?> detail) {
    final ctrl = dialogController;
    if (ctrl == null) return;
    final payload = jsonEncode(detail);
    final js = "window.__$event = $payload;"
        "window.dispatchEvent(new CustomEvent('$event', { detail: window.__$event }));";
    ctrl.runJavaScript(js).catchError((_) {/* dialog1 not loaded yet */});
  }

  /// Warm the language app with schedules + lists on page load, mirroring
  /// the playlist warm-push. Routed through the bridge's own ops so the
  /// payloads stay single-sourced; the stray acks are harmless.
  Future<void> _pushNotifStateToDialog() async {
    await _notifBridge.handle('{"op":"getSchedules"}');
    await _notifBridge.handle('{"op":"getLists"}');
    await _notifBridge.handle('{"op":"getNotifications"}');
  }

  /// Sweep, then refresh the webpage's notification feed — fires the sweep
  /// just recorded should appear in the in-page inbox without a reload.
  Future<void> _sweepThenPush() async {
    await notifService.sweep();
    await _pushNotifStateToDialog();
  }

  /// Notification delivery init — runs on EVERY platform (unlike the tagging
  /// DB probe): on platforms without sqlite the dao resolves null and every
  /// sweep no-ops (self-disable), but the channel and capabilities must still
  /// initialize so getCapabilities answers honestly.
  Future<void> _initNotifDelivery() async {
    await NotifSettings.init();
    await notifChannel.init(NotifCallbacks(
      onOpened: _onNotificationOpened,
      onAction: _onNotificationAction,
    ));
    final nc = notifChannel;
    if (nc is FlutterNotifChannel) {
      final launch = await nc.launchPayload();
      if (launch != null) {
        // Record the tap BEFORE the launch sweep below: the sweep must see
        // this fire as delivered-and-seen, not as a missed fire to re-post.
        // The post-frame callback (which needs the widget tree) repeats
        // recordOpened harmlessly — it is idempotent — and navigates.
        await notifService.recordOpened(launch);
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => _onNotificationOpened(launch));
      }
    }
    await notifService.sweep(); // launch catch-up (spec: sweep callers)
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      _notifTimer.start();
    }
  }

  /// Notification body tap → record response, open dialog1 at the item's
  /// open_url (fallback: plain dialog1), and tell the webpage
  /// (spec: cupitorNotificationOpened event; external ids only).
  Future<void> _onNotificationOpened(String payloadJson) async {
    await notifService.recordOpened(payloadJson);
    Map<String, dynamic> p;
    try {
      p = jsonDecode(payloadJson) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final openUrl = p['open_url'] as String?;
    // When a page load is in flight (cold start, or an open_url navigation)
    // an immediate emit lands in the JS context that's about to be replaced
    // and is lost. Stash the event; onPageFinished replays it.
    var navigating = false;
    if (openUrl != null && openUrl.isNotEmpty) {
      navigating = true;
      _openDialogAtUrl(openUrl);
    } else if (dialogController != null) {
      _showDialog1();
    } else {
      navigating = true;
      _openDialogWithWebview(''); // build + show at the default study page
    }
    final detail = <String, Object?>{
      'external_key': p['list_ek'],
      'item_external_id': p['item_eid'],
      'payload': p['echo'],
    };
    if (navigating) {
      _pendingNotifOpenedEvent = detail;
    } else {
      _emitNotifEvent('cupitorNotificationOpened', detail);
    }
  }

  /// Set while a notification-tap navigation is loading; replayed by the
  /// dialog's onPageFinished so the (re)loaded page still gets the event.
  Map<String, Object?>? _pendingNotifOpenedEvent;

  /// Foreground action button → grade via the shared service path, then
  /// mirror to the webpage so its state doesn't drift (spec:
  /// cupitorNotifGraded) and refresh the lists push.
  Future<void> _onNotificationAction(
      String actionId, String payloadJson) async {
    final graded = await notifService.handleAction(actionId, payloadJson);
    if (graded == null) return;
    final ((listEk, itemEid), grade) = graded;
    _emitNotifEvent('cupitorNotifGraded', {
      'external_key': listEk,
      'item_external_id': itemEid,
      'grade': grade,
      'source': 'action',
    });
    await _pushNotifStateToDialog();
  }

  /// Handle a JSON message from the language app via the
  /// `PlaylistBridge` JavaScript channel.
  ///
  /// Supported ops:
  ///  * `getPlaylists` — dispatch the current payload as a
  ///    `cupitorPlaylists` CustomEvent for the requester to read.
  ///  * `openEpub` — find an EPUB by `book_key` (SHA-1) in the persisted
  ///    library, close dialog1, and open the reader at the given
  ///    `chapter_idx`. Reports failure back via the same CustomEvent
  ///    channel so the language app can surface an error.
  ///  * `globalSearch` — full-text search across every EPUB in the
  ///    library. `{op:'globalSearch', query:'cat|dog'}`. Result set
  ///    dispatched as `cupitorGlobalSearchResults` CustomEvent.
  ///  * `viewState` — the webapp's player/practice view opened or closed.
  ///    `{op:'viewState', view:'player'|'practice'|''}`. Persisted so the
  ///    dialog can be reopened at launch; the webapp restores the view itself
  ///    once its page is running.
  ///  * `captureFiled` — a sent capture has been written into a playlist,
  ///    so close dialog1 and give the user back what they sent it from.
  ///    `{op:'captureFiled', playlist:'Swedish'}`. The webapp withholds this
  ///    while more blocks are queued, so the next picker isn't hidden.
  Future<void> _handlePlaylistBridge(String raw) async {
    Map<String, dynamic>? m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) { return; }
    final op = m['op'] as String?;
    if (op == 'getPlaylists') {
      await _pushPlaylistsToDialog();
      return;
    }
    if (op == 'openEpub') {
      final bookKey = (m['book_key'] as String?) ?? '';
      final chapterIdx = (m['chapter_idx'] as num?)?.toInt() ?? 0;
      final match = (m['match'] as String?)?.trim();
      if (bookKey.isEmpty) return;
      await _openEpubByKey(
        bookKey,
        chapterIdx,
        highlight: (match == null || match.isEmpty) ? null : match,
      );
      return;
    }
    if (op == 'globalSearch') {
      final query = (m['query'] as String?) ?? '';
      if (query.trim().isEmpty) return;
      // `partial` on the op is an optional per-query override. When
      // omitted, the device-level Index Settings toggle is used.
      final raw = m['partial'];
      final partialOverride = raw is bool ? raw : null;
      await _handleGlobalSearchOp(query, partialOverride: partialOverride);
      return;
    }
    if (op == 'cancelSearch') {
      _cancelGlobalSearch();
      return;
    }
    if (op == 'captureFiled') {
      _onCaptureFiled((m['message'] as String?) ?? '');
      return;
    }
    if (op == 'viewState') {
      await _rememberWebappView((m['view'] as String?) ?? '');
      return;
    }
  }

  // ── Global search: streaming bridge state ───────────────────────
  //
  // At most one search runs at a time. Starting a new `globalSearch`
  // op silently cancels any prior in-flight one. Hits are batched
  // per-book (progress boundary) and dispatched as delta events with
  // `done: false`; a final event with `done: true` closes the stream.
  StreamSubscription<GlobalSearchEvent>? _globalSearchSub;
  final List<GlobalSearchHit> _globalSearchBuffer = [];
  int _globalSearchEmitted = 0;
  String _globalSearchQuery = '';
  bool _globalSearchPartial = false;
  // Monotonic token used to disambiguate stream events from stale
  // subscriptions during the async cancellation window. Each new
  // search bumps this; the listen callback captures it in a local
  // closure and no-ops when the token has moved on.
  int _globalSearchToken = 0;
  static const int _kGlobalSearchCap = 200;

  /// Kick off a streaming global-search on behalf of the language app.
  /// Cancels any prior search. Events dispatched into dialog1:
  ///   { query, partial, hits: [delta], done: false, hits_capped: bool }
  ///   { query, partial, hits: [],      done: true,  hits_capped: bool }
  ///
  /// [partialOverride] mirrors the op's optional `partial` field —
  /// null falls through to the device-level Index Settings toggle.
  Future<void> _handleGlobalSearchOp(String query, {bool? partialOverride}) async {
    _cancelGlobalSearch();
    _globalSearchQuery = query;
    _globalSearchEmitted = 0;
    _globalSearchBuffer.clear();
    // Resolve the effective mode once so every batch this run dispatches
    // labels itself consistently (even if the user toggles the device
    // setting mid-search).
    _globalSearchPartial = partialOverride ?? SearchIndex.partialMatchEnabled.value;
    // Bump the identity token BEFORE listening. The closure below
    // captures this local value; any callback from a superseded
    // subscription (still draining in the async cancellation window)
    // will see `token != _globalSearchToken` and no-op — its hit can't
    // leak into the new query's buffer.
    final token = ++_globalSearchToken;
    _globalSearchSub = GlobalSearch.search(
      query,
      maxTotalHits: _kGlobalSearchCap,
      partialOverride: partialOverride,
    ).listen((ev) {
      if (token != _globalSearchToken) return;
      if (ev is GlobalSearchHitEvent) {
        _globalSearchBuffer.add(ev.hit);
        _globalSearchEmitted++;
      } else if (ev is GlobalSearchProgressEvent) {
        // Flush the accumulated hits at every book boundary — cheap
        // batching that keeps event count proportional to book count
        // rather than hit count.
        if (_globalSearchBuffer.isNotEmpty) {
          _dispatchGlobalSearchBatch(done: false, capped: false);
        }
      } else if (ev is GlobalSearchDone) {
        // Flush any remaining hits, then send the closing event.
        if (_globalSearchBuffer.isNotEmpty) {
          _dispatchGlobalSearchBatch(
            done: false,
            capped: _globalSearchEmitted >= _kGlobalSearchCap,
          );
        }
        _dispatchGlobalSearchBatch(
          done: true,
          capped: _globalSearchEmitted >= _kGlobalSearchCap,
        );
        _globalSearchSub = null;
      }
    }, onError: (_) {
      if (token != _globalSearchToken) return;
      _dispatchGlobalSearchBatch(done: true, capped: false);
      _globalSearchSub = null;
    }, onDone: () {
      if (token != _globalSearchToken) return;
      // Belt-and-suspenders: if the stream ends without a final
      // GlobalSearchDone (shouldn't happen, but crash-safe), still
      // close the client-side stream.
      if (_globalSearchSub != null) {
        _dispatchGlobalSearchBatch(done: true, capped: false);
        _globalSearchSub = null;
      }
    });
  }

  void _cancelGlobalSearch() {
    final sub = _globalSearchSub;
    if (sub == null) return;
    _globalSearchSub = null;
    // Bump the identity token FIRST so any in-flight callback from the
    // subscription being cancelled bails out before it can mutate the
    // shared buffer or dispatch under the wrong query/mode.
    _globalSearchToken++;
    sub.cancel();
    // Tell the client the current query is closing prematurely so it
    // can drop any stale-result-guard state without waiting for a
    // timeout. `hits: []` — anything already emitted stays with the
    // client under its accumulated snapshot.
    _dispatchGlobalSearchBatch(done: true, capped: false, cancelled: true);
  }

  void _dispatchGlobalSearchBatch({
    required bool done,
    required bool capped,
    bool cancelled = false,
  }) {
    final ctrl = dialogController;
    // Snapshot + clear the buffer so subsequent hits (post-progress)
    // start a fresh batch.
    final delta = List<GlobalSearchHit>.from(_globalSearchBuffer);
    _globalSearchBuffer.clear();
    if (ctrl == null) return;
    final payload = jsonEncode({
      'query': _globalSearchQuery,
      'partial': _globalSearchPartial,
      'hits': [for (final h in delta) h.toJson()],
      'done': done,
      'hits_capped': capped,
      if (cancelled) 'cancelled': true,
    });
    final js = 'window.__cupitorGlobalSearchResults = $payload;'
        "window.dispatchEvent(new CustomEvent('cupitorGlobalSearchResults', "
        '{ detail: window.__cupitorGlobalSearchResults }));';
    ctrl.runJavaScript(js).catchError((_) {/* dialog1 gone */});
  }

  /// Open the global-search screen from the Tools drawer. Reuses the
  /// same `_openEpubByKey` flow the language app uses via the JS
  /// bridge — one code path, one set of "book file moved / missing"
  /// error messages.
  Future<void> _openGlobalSearch() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GlobalSearchScreen(
        onOpen: (bookKey, chapterIdx, highlight) async {
          Navigator.of(context).pop();
          await _openEpubByKey(bookKey, chapterIdx, highlight: highlight);
        },
      ),
    ));
  }

  /// Look up a persisted EPUB library entry by SHA-1 key, then open
  /// the EPUB reader at the given chapter. Closes dialog1 first so the
  /// reader takes over the screen. If the file has moved / been
  /// deleted since the library entry was recorded, shows a snackbar
  /// and leaves dialog1 open.
  Future<void> _openEpubByKey(
    String bookKey,
    int chapterIdx, {
    String? highlight,
  }) async {
    try {
      final lib = await _ensureEpubLibrary();
      final entry = lib.entries.firstWhere(
        (e) => e.key == bookKey,
        orElse: () => EpubLibraryEntry(key: '', path: '', title: ''),
      );
      if (entry.key.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'EPUB not in library on this device.',
          )),
        );
        return;
      }
      final file = File(entry.path);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('EPUB file missing: ${entry.path}')),
        );
        return;
      }
      // Rewrite the reading state's chapterIdx BEFORE opening so the
      // reader loads at the requested chapter (there's no init-param
      // for it on EpubReaderScreen — resume state is the mechanism).
      final state = await EpubReadingState.load(bookKey);
      // Clamp against the parsed book after openFile — but chapter
      // count is close enough via a load-then-clamp inside the reader
      // itself when the file opens.
      state.chapterIdx = chapterIdx < 0 ? 0 : chapterIdx;
      state.scrollPct = 0.0;
      await state.save(bookKey);
      if (!mounted) return;
      // Dismiss dialog1 (if visible) so the reader can present cleanly.
      if (_dialog1Visible) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
      await _launchEpubReader(file, initialHighlight: highlight);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open EPUB: $e')),
      );
    }
  }

  void _handleLinkLongPress(String url) {
    final link = url.trim();
    if (link.isEmpty || !mounted) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                link,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetCtx).textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Copy Link'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                Clipboard.setData(ClipboardData(text: link));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied'), duration: Duration(seconds: 1)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _ensureDialog1Tts() async {
    if (_dialog1Tts != null) return;
    final tts = FlutterTts();
    _dialog1Tts = tts;
    try {
      // Speak/stop one utterance at a time and rely on these callbacks to
      // advance the queue. awaitSpeakCompletion would also work but blocks
      // the speak call — handlers keep us reactive to cancel().
      tts.setStartHandler(() {
        final id = _dialog1TtsActiveJsId;
        if (id != null) {
          dialogController?.runJavaScript('window.__cupitorTtsStart && window.__cupitorTtsStart($id);');
        }
      });
      tts.setCompletionHandler(() {
        _ttsFinishCurrent(error: null);
      });
      tts.setCancelHandler(() {
        // System cancelled (e.g. another app took audio focus). Treat as end.
        _ttsFinishCurrent(error: null);
      });
      tts.setErrorHandler((msg) {
        _ttsFinishCurrent(error: msg?.toString() ?? 'tts-error');
      });
    } catch (_) { /* best-effort */ }
  }

  void _ttsFinishCurrent({String? error}) {
    final id = _dialog1TtsActiveJsId;
    _dialog1TtsActiveJsId = null;
    _dialog1TtsBusy = false;
    if (id != null) {
      if (error == null) {
        dialogController?.runJavaScript('window.__cupitorTtsEnd && window.__cupitorTtsEnd($id);');
      } else {
        final esc = jsonEncode(error);
        dialogController?.runJavaScript('window.__cupitorTtsError && window.__cupitorTtsError($id, $esc);');
      }
    }
    _ttsPumpQueue();
  }

  Future<void> _ttsPumpQueue() async {
    if (_dialog1TtsBusy) return;
    if (_dialog1TtsQueue.isEmpty) return;
    final next = _dialog1TtsQueue.removeAt(0);
    _dialog1TtsBusy = true;
    _dialog1TtsActiveJsId = next['id'] as int;
    final tts = _dialog1Tts;
    if (tts == null) { _ttsFinishCurrent(error: 'tts-unavailable'); return; }
    try {
      final lang = (next['lang'] as String?)?.trim();
      if (lang != null && lang.isNotEmpty) {
        try { await tts.setLanguage(lang); } catch (_) {}
      }
      // Web rate is 0.1–10 with 1.0 = normal. flutter_tts rate on Android maps
      // 0.0–1.0 with ~0.5 being normal; iOS/macOS uses 0.0–1.0 with ~0.5
      // normal too. Halving keeps "normal" at "normal" and clamps to [0.1, 1.0].
      final webRate = (next['rate'] as num?)?.toDouble() ?? 1.0;
      final ttsRate = (webRate / 2.0).clamp(0.1, 1.0);
      try { await tts.setSpeechRate(ttsRate); } catch (_) {}
      final pitch = ((next['pitch'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
      try { await tts.setPitch(pitch); } catch (_) {}
      final volume = ((next['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
      try { await tts.setVolume(volume); } catch (_) {}
      await tts.speak((next['text'] as String?) ?? '');
    } catch (e) {
      _ttsFinishCurrent(error: e.toString());
    }
  }

  void _handleTtsBridge(JavaScriptMessage msg) {
    Map<String, dynamic> req;
    try { req = jsonDecode(msg.message) as Map<String, dynamic>; }
    catch (_) { return; }
    final type = req['type'] as String?;
    if (type == null) return;
    _ensureDialog1Tts();
    switch (type) {
      case 'speak':
        _dialog1TtsQueue.add(req);
        _ttsPumpQueue();
        break;
      case 'cancel':
        _dialog1TtsQueue.clear();
        _dialog1Tts?.stop();
        _ttsFinishCurrent(error: null);
        break;
      case 'pause':
        _dialog1Tts?.pause();
        break;
      case 'resume':
        // flutter_tts has no resume on Android — best-effort no-op.
        break;
    }
  }

  /// `runJavaScriptReturningResult` hands back a JSON-encoded string on
  /// Android. Decoding it rather than stripping quotes matters now that the
  /// value can be a whole sentence: a naive replace eats every quote mark in
  /// the text and leaves `\n` and `\u00e5` as literals.
  String _decodeJsString(Object? raw) {
    final s = raw?.toString() ?? '';
    try {
      final decoded = jsonDecode(s);
      if (decoded is String) return decoded.trim();
    } catch (_) {}
    return s.replaceAll('"', '').trim();
  }

  String jsCodeToFilterData(String text) {
    final escaped = text.replaceAll("'", "\\'");
    // Token is intentionally NOT passed here — GitHub API calls are proxied
    // through the GitHubProxy JavaScriptChannel so the token stays in Flutter.
    return "window.dispatchEvent(new CustomEvent('filterData', { detail: { text: '$escaped' } }));";
  }

  /// Builds the JS that fires a `capturedSubtitle` CustomEvent on the dialog1
  /// page. The page listens for this to handle multi-line subtitle captures
  /// distinctly from single-word lookups (`filterData`).
  ///
  /// Detail shape (SRT-reconstructable):
  /// ```
  /// {
  ///   query:       "<the matched search word>",
  ///   sourceLang:  "sv" | "es" | ...,
  ///   targetLang:  "en",
  ///   matchIndex:  <int — index into `lines` of the matched line>,
  ///   lines:       [ { index, start, end, text }, ... ],
  ///   translation: [ { index, start, end, text }, ... ]   // same length, parallel
  /// }
  /// ```
  /// `start` and `end` are seconds (doubles). The page can format them to
  /// SRT timestamps (`HH:MM:SS,mmm`) by itself.
  String _jsCodeForCapturedSubtitle(Map<String, dynamic> payload) {
    final detail = jsonEncode(payload);
    return "window.dispatchEvent(new CustomEvent('capturedSubtitle', { detail: $detail }));";
  }

  // Set when capture happens before dialog1 has ever been initialized — the
  // event is then fired in onPageFinished, after the page is ready to listen.
  Map<String, dynamic>? _pendingCapturedSubtitle;

  /// Fills in the video's channel and a clean title first: the webapp files
  /// the capture under them, and a capture path that lacks them would file a
  /// known video under a new name.
  Future<void> _sendCapturedSubtitleToDialog1(Map<String, dynamic> payload) async {
    _dispatchCapturedSubtitle(await withCaptureMeta(payload, fetchYouTubeOembed));
  }

  void _dispatchCapturedSubtitle(Map<String, dynamic> payload) {
    if (dialogController != null) {
      dialogController!.runJavaScript(_jsCodeForCapturedSubtitle(payload));
      _showDialog1();
      return;
    }
    // No dialog1 controller yet — let _openDialogWithWebview spin one up,
    // then dispatch from onPageFinished once the listener is alive.
    _pendingCapturedSubtitle = payload;
    _openDialogWithWebview('');
  }

  // ---------------------------------------------------------------------
  // Caption capture — selected subtitle lines from snippet.js's sidebar.
  // Contract: docs/superpowers/specs/2026-09-06-caption-capture-design.md
  // ---------------------------------------------------------------------

  /// Its own slot rather than sharing `_pendingCapturedSubtitle`: the two
  /// events are independent and either could be waiting on dialog1.
  /// Captures waiting for dialog1's page to exist.
  ///
  /// A list, not a single slot. Two sends in quick succession are easy to
  /// produce, and the second overwriting the first loses the user's text with
  /// nothing said about it.
  final List<Map<String, dynamic>> _pendingCaptionCaptures = [];

  /// dialog1's own route while it is on screen.
  ///
  /// Kept so a programmatic close can remove exactly that route. Popping the
  /// navigator would take whatever is on top instead, and a dialog2 panel is
  /// pushed above dialog1 on the same navigator.
  ModalRoute<dynamic>? _dialog1Route;

  /// True once dialog1's page has finished loading, which is when its
  /// listeners exist. Dispatching an event before that drops it silently.
  bool _dialog1Loaded = false;

  void _handleCaptionCollector(WebViewController page, JavaScriptMessage msg) {
    Object? raw;
    try {
      raw = jsonDecode(msg.message);
    } catch (_) {
      return; // non-JSON is dropped silently, as with the other channels
    }
    final detail = buildCaptionCaptureDetail(raw, fallbackLang: _selectedLanguage);
    // Nothing usable in the payload — say nothing rather than opening dialog1
    // on an empty capture.
    if (detail == null) return;
    _holdVideosForLookup(page);
    // A failed send never shows dialog1, so nothing would ever release.
    _sendCaptionCaptureToDialog1(detail)
        .catchError((_) => _releaseVideosAfterLookup());
  }

  /// Pauses the videos playing in [page] while dialog1 opens over it; they
  /// play again when dialog1 closes (or is minimized). Only what was playing
  /// is held, so a video the user had paused stays paused.
  void _holdVideosForLookup(WebViewController page) {
    // A second page holding while the first is still held would leave the
    // first one paused for good, so let it go first.
    final previous = _lookupHoldController;
    if (previous != null && !identical(previous, page)) {
      previous.runJavaScript(kReleaseVideosAfterLookupJs).catchError((_) {});
    }
    _lookupHoldController = page;
    page.runJavaScript(kHoldVideosForLookupJs).catchError((_) {});
  }

  void _releaseVideosAfterLookup() {
    final page = _lookupHoldController;
    _lookupHoldController = null;
    page?.runJavaScript(kReleaseVideosAfterLookupJs).catchError((_) {});
  }

  /// Deliberately a different event from `capturedSubtitle`, which drives the
  /// YouTube and filmot subtitle-study flows. A separate event keeps those
  /// untouched and lets the webapp half ship independently — with no listener
  /// registered this is simply inert.
  String _jsCodeForCaptionCapture(Map<String, dynamic> detail) =>
      "window.dispatchEvent(new CustomEvent('cupitorCaptionCapture', "
      "{ detail: ${jsonEncode(detail)} }));";

  /// Throws if the page refuses the event — a dead renderer, a navigation
  /// mid-flight. The caller decides whether that is worth telling the user
  /// about.
  Future<void> _sendCaptionCaptureToDialog1(Map<String, dynamic> detail) async {
    if (dialogController != null && _dialog1Loaded) {
      await dialogController!.runJavaScript(_jsCodeForCaptionCapture(detail));
      _showDialog1();
      return;
    }
    // The page is not there to receive it yet. Hold it until it is, rather
    // than firing into a document with no listener registered.
    _pendingCaptionCaptures.add(detail);
    if (dialogController == null) {
      _openDialogWithWebview('');
    } else {
      _showDialog1();
    }
  }

  /// The page's address as every other capture path sees it: with whatever
  /// start offset the player has written into it taken out, and the name of
  /// the parameter that offset lives under.
  ///
  /// Answered by the injected snippet, because the site table that names the
  /// parameter is fetched at runtime and lives there. `('', '')` when the page
  /// cannot answer — an older snippet, a page it never installed into — and
  /// the caller then files the address it already had.
  Future<(String, String)> _pageCaptureIdentity() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        'window.__cupCaptureIdentity ? window.__cupCaptureIdentity() : ""',
      );
      // Android hands back a JSON-encoded string; WKWebView the value itself.
      var s = raw.toString();
      try {
        final once = jsonDecode(s);
        if (once is String) s = once;
      } catch (_) {}
      final m = jsonDecode(s);
      if (m is! Map) return ('', '');
      return (
        (m['url'] ?? '').toString(),
        (m['timeParam'] ?? '').toString(),
      );
    } catch (_) {
      return ('', '');
    }
  }

  /// SharedPreferences key holding the webapp view that was on screen when we
  /// last heard from it: 'player', 'practice', or absent for none.
  static const String _kOpenWebappViewPref = 'openWebappView';

  /// Records what the webapp says it has open.
  ///
  /// The webapp keeps its own copy and restores the view itself — but only
  /// once it is running, and it only runs inside dialog1. Nothing reopens that
  /// dialog at launch, so without this the page never loads and its own
  /// restore never gets the chance to fire.
  Future<void> _rememberWebappView(String view) async {
    final v = (view == 'player' || view == 'practice') ? view : '';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (v.isEmpty) {
        await prefs.remove(_kOpenWebappViewPref);
      } else {
        await prefs.setString(_kOpenWebappViewPref, v);
      }
    } catch (_) {
      // Losing this costs one auto-reopen, never the session itself.
    }
  }

  /// Brings dialog1 back at launch when the webapp was mid-session.
  ///
  /// Only opens the dialog. Which view comes back, at which card, and whether
  /// it makes any sound are all the webapp's business — it has the queue and
  /// the position, and it restores them as soon as its page runs.
  Future<void> _reopenWebappViewIfAny() async {
    String view = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      view = prefs.getString(_kOpenWebappViewPref) ?? '';
    } catch (_) {
      return;
    }
    if (view.isEmpty || !mounted) return;
    // Already up — the user beat us to it during startup.
    if (dialogController != null) return;
    _openDialogWithWebview('');
  }

  /// Puts dialog1 away once the webapp reports a capture filed, and says here
  /// what happened.
  ///
  /// The send is what brought the webapp on screen; with the block written
  /// there is nothing left there to look at, so the user goes back to the page
  /// or book they sent it from.
  ///
  /// [message] is reported from here rather than by the page, because a toast
  /// drawn inside dialog1 is torn down with it — the confirmation would flash
  /// and vanish with the thing confirming it.
  void _onCaptureFiled(String message) {
    // Remove dialog1's own route rather than popping the navigator, which
    // takes whatever is topmost. Pressing Add means dialog1 WAS topmost, so a
    // pop would land right today — but that is a property of the webapp's
    // button, not of this code, and naming the route costs nothing.
    // Skipping it once the route has gone is the safe branch — a capture filed
    // with dialog1 already closed has nothing left to close, and the message
    // below is still worth showing.
    final route = _dialog1Route;
    if (mounted && _dialog1Visible && route != null && route.isActive) {
      // Asking the route which navigator owns it beats assuming: no guess to
      // get wrong if dialog1 is ever shown from somewhere else.
      route.navigator?.removeRoute(route);
    }
    final text = message.trim();
    if (text.isEmpty || !mounted) return;
    // The root messenger, which is right because dialog1 has just gone and
    // nothing else is covering the page. A dialog2 owns a nested messenger and
    // would hide this (see _showDialog2SnackBar), but one cannot be on top
    // here: the Add button that sends this is inside dialog1.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  /// Pushes ONE sentence from the tagging sheet to the language webapp, which
  /// offers its playlist picker and files the sentence as a manual card.
  ///
  /// Rides the caption-capture contract as a `page` block rather than
  /// inventing a second one: same validation, same webapp listener, same
  /// dialog. Returns a message for the sheet to show, or null when the send
  /// went through — the webapp comes to the front and speaks for itself.
  Future<String?> _sendSentenceToWebappPlaylist({
    required String text,
    required String title,
    required String url,
    String timeParam = '',
  }) async {
    final detail = buildCaptionCaptureDetail(
      sentenceCaptureBlock(
          text: text, title: title, url: url, timeParam: timeParam),
      fallbackLang: _selectedLanguage,
    );
    if (detail == null) return 'Nothing to send.';
    try {
      await _sendCaptionCaptureToDialog1(detail);
    } catch (e) {
      // Silence here would be the worst outcome: the sheet closes the loop by
      // showing nothing, and the user believes the sentence was filed.
      return 'Could not reach Cupitor: $e';
    }
    return null;
  }

  Widget _errorView(String message, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red),
            SizedBox(height: 12),
            Text('Failed to load page', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                message,
                style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.red.shade800),
              ),
            ),
            SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh),
              label: Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _appBarTimer;
  DateTime? _lastTapTime;
  // Long-press tracking — fires a top-bar toggle if the pointer stays down
  // for ~500ms without significant movement. We must NOT consume the touch
  // (the WebView still needs it for native text selection), so this lives
  // inside the existing translucent Listener.
  Timer? _longPressTimer;
  Offset? _pointerDownPos;
  static const double _kLongPressMoveSlop = 12.0;
  static const Duration _kLongPressDuration = Duration(milliseconds: 500);

  void _handleDoubleTapDetection() {
    final now = DateTime.now();
    if (_lastTapTime != null && now.difference(_lastTapTime!) < const Duration(milliseconds: 400)) {
      _lastTapTime = null;
      _toggleAppBar();
    } else {
      _lastTapTime = now;
    }
  }

  void _toggleAppBar() {
    // Never hide the bar while voice input is active — the user needs to see
    // the live mic state and the Stop control for as long as recording runs.
    if (_isListening) {
      if (!_showAppBar) _showAppBarWithTimer();
      return;
    }
    if (_showAppBar) {
      _appBarTimer?.cancel();
      setState(() => _showAppBar = false);
    } else {
      _showAppBarWithTimer();
    }
  }

  void _onPagePointerDown(PointerDownEvent e) {
    _handleDoubleTapDetection();
    _pointerDownPos = e.position;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kLongPressDuration, () {
      _longPressTimer = null;
      _toggleAppBar();
    });
  }

  void _onPagePointerMove(PointerMoveEvent e) {
    if (_longPressTimer == null || _pointerDownPos == null) return;
    if ((e.position - _pointerDownPos!).distance > _kLongPressMoveSlop) {
      _longPressTimer?.cancel();
      _longPressTimer = null;
    }
  }

  void _onPagePointerUp(PointerUpEvent _) {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _pointerDownPos = null;
  }

  void _showAppBarWithTimer() {
    setState(() => _showAppBar = true);
    _appBarTimer?.cancel();
    // Don't auto-hide app bar when voice input is active
    if (_autoHideAppBar && !_isListening) {
      _appBarTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _showAppBar = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isControllerReady) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final appBar = AppBar(
      title: Focus(
        onFocusChange: (focused) {
          if (_autoHideAppBar) setState(() => _urlBarFocused = focused);
          if (focused) { _appBarTimer?.cancel(); }
        },
        child: RawAutocomplete<HistoryEntry>(
          textEditingController: _urlController,
          focusNode: _urlFocusNode,
          // Picking a suggestion puts its address in the field; the load is
          // triggered from onSelected below.
          displayStringForOption: (e) => e.url,
          optionsBuilder: (value) {
            final q = value.text.trim();
            if (q.isEmpty) return const Iterable<HistoryEntry>.empty();
            // An untouched bar holds the address of the page already on
            // screen — this is its state on every tap into the field, before
            // a character is typed. Suggesting anything then is noise, and
            // the page itself is never a useful suggestion.
            final here = (_lastLoadedUrl ?? '').trim();
            if (q == here || q == here.split('#').first) {
              return const Iterable<HistoryEntry>.empty();
            }
            return HistoryStore.suggest(q).where((e) => e.url != q);
          },
          onSelected: (_) {
            _urlSuggestionPicked = true;
            _loadUrl();
            FocusManager.instance.primaryFocus?.unfocus();
          },
          optionsViewBuilder: (context, onSelected, options) {
            // Read during build and never written back into the tree, so this
            // cannot trigger a rebuild; it is only consulted on Enter.
            final highlighted = AutocompleteHighlightedOption.of(context);
            _urlSuggestionHighlightMoved = highlighted > 0;
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  // Width is left alone so the list matches the field it
                  // drops out of; the framework bounds it to exactly that.
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: options.length,
                    itemBuilder: (context, i) {
                      final e = options.elementAt(i);
                      return ListTile(
                        dense: true,
                        selected: i == highlighted,
                        selectedTileColor:
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                        leading: const Icon(Icons.history, size: 18),
                        title: Text(e.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          e.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () => onSelected(e),
                      );
                    },
                  ),
                ),
              ),
            );
          },
          fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
            return TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                hintText: 'Enter URL',
                border: InputBorder.none,
                suffixIcon: IconButton(icon: Icon(Icons.arrow_forward), onPressed: () {
                  _loadUrl();
                  FocusManager.instance.primaryFocus?.unfocus();
                }),
              ),
              keyboardType: TextInputType.url,
              onTap: () => controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length),
              onSubmitted: (_) {
                _urlSuggestionPicked = false;
                // Only when the user arrowed to a suggestion. onSelected runs
                // synchronously from here and sets the flag below.
                if (_urlSuggestionHighlightMoved) onFieldSubmitted();
                if (!_urlSuggestionPicked) _loadUrl();
                FocusManager.instance.primaryFocus?.unfocus();
              },
            );
          },
        ),
      ),
      actions: _urlBarFocused ? null : [
        ValueListenableBuilder<bool>(
          valueListenable: _pageLoading,
          builder: (context, loading, __) => loading
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 20, height: 20,
                    // The toolbar's icon colour, so it reads on any app bar.
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: IconTheme.of(context).color),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        IconButton(
          icon: Icon(Icons.tune_outlined),
          tooltip: 'Tools',
          onPressed: _showToolsDrawer,
        ),
        if (_currentPdfUrl != null) ...([
          _isExtractingPdf
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
              )
            : IconButton(
                icon: Icon(_isTextView ? Icons.picture_as_pdf : Icons.text_snippet_outlined),
                tooltip: _isTextView ? 'Switch to PDF view' : 'Switch to text view',
                onPressed: _togglePdfTextView,
              ),
        ]),
        IconButton(
          icon: Icon(_showFindBar ? Icons.search_off : Icons.search),
          tooltip: _showFindBar ? 'Close find' : 'Find in page',
          onPressed: () {
            setState(() {
              _showFindBar = !_showFindBar;
              if (!_showFindBar) {
                _findController.clear();
                _clearFindHighlights();
              }
            });
          },
        ),
        GestureDetector(
          // Long-press = enter continuous-listen mode (until next tap to stop).
          // Tap = original one-shot voice input.
          //
          // NOTE: on Android the inner IconButton must NOT set `tooltip:`.
          // Flutter's Tooltip claims the touch long-press to show itself, and
          // being the inner gesture detector it wins the arena over this outer
          // onLongPress — so the popup appeared but recording never started.
          // macOS shows tooltips on hover (no long-press conflict), so we keep
          // the hint there.
          onLongPress: () {
            if (Platform.isAndroid && !_isListening) {
              HapticFeedback.mediumImpact();
            }
            _startContinuousVoiceCapture();
          },
          child: ValueListenableBuilder<bool>(
            valueListenable: _isListeningNotifier,
            builder: (_, listening, __) => IconButton(
              tooltip: Platform.isAndroid
                  ? null
                  : (listening
                      ? (_continuousVoiceActive ? 'Stop continuous capture' : 'Stop listening')
                      : 'Voice input (long-press for continuous)'),
              icon: Icon(
                listening ? Icons.mic : Icons.mic_none,
                color: listening
                    ? (_continuousVoiceActive ? Colors.red : Colors.redAccent)
                    : null,
              ),
              onPressed: () {
                if (_continuousVoiceActive) {
                  _stopContinuousVoiceCapture();
                } else {
                  _toggleVoiceInput();
                }
              },
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.open_in_new),
          onPressed: () async {
            String text = '';
            if (_currentPdfUrl != null && !_isTextView
                && _pdfSelectedText.isNotEmpty) {
              text = _pdfSelectedText;
            } else {
              const js = '''
                (function () {
                  function fromWindow(w) {
                    try {
                      var s = w.getSelection().toString().trim();
                      if (s) return s;
                      for (var i = 0; i < w.frames.length; i++) {
                        var found = fromWindow(w.frames[i]);
                        if (found) return found;
                      }
                    } catch (e) {}
                    return '';
                  }
                  var s = fromWindow(window);
                  if (s) return s;
                  // A cross-origin reader's selection cannot be read from
                  // here at all — getSelection() on its window throws, which
                  // the catch above swallows, and an embedded e-book reader is
                  // exactly that case. snippet.js keeps the last selection the
                  // frame agent reported to it, and this is the only route by
                  // which that text reaches the host.
                  try {
                    if (window.__cupSelection) {
                      return String(window.__cupSelection() || '');
                    }
                  } catch (e) {}
                  return '';
                })();
              ''';
              // Timeout the JS call: if the main WebView's renderer is wedged
              // (e.g. after a heavy page in a dialog jammed the shared renderer
              // process), runJavaScriptReturningResult never resolves and the
              // await blocks here forever — meaning open_in_new appears to do
              // nothing. Falling back to empty text lets the dialog still open
              // so the user can use the Reload button to recover.
              try {
                final result = await _controller
                    .runJavaScriptReturningResult(js)
                    .timeout(const Duration(seconds: 2));
                text = _decodeJsString(result);
              } catch (_) {}
            }
            _openDialogWithWebview(text);
          },
        ),
      ],
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final hideFullscreen = _hideAndroidFullscreen;
        if (hideFullscreen != null) {
          hideFullscreen();
          return;
        }
        if (_currentPdfUrl != null) {
          // Dismiss PDF overlay — the WebView still holds the previous page
          // since PDF navigation was prevented (NavigationDecision.prevent).
          setState(() {
            _currentPdfUrl = null;
            _extractedPdfHtml = null;
            _isTextView = false;
            _isShowingOurHtml = false;
          });
          return;
        }
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            // Main content — fills entire screen
            ColorFiltered(
              colorFilter: _isEinkMode ? einkColorFilter : identityColorFilter,
              child: Stack(
                children: [
                  pageCursor(WebViewWidget(controller: _controller)),
                  if (_currentPdfUrl != null && !_isTextView)
                    Positioned.fill(
                      child: PdfViewer.uri(
                        Uri.parse(_currentPdfUrl!),
                        controller: _pdfViewerController ??= PdfViewerController(),
                        params: PdfViewerParams(
                          enableTextSelection: true,
                          onTextSelectionChange: (selections) {
                            final text = selections
                                .map((s) => s.ranges.map((r) =>
                                  s.pageText.fullText.substring(r.start, r.end)
                                ).join())
                                .join(' ')
                                .trim();
                            _pdfSelectedText = text;
                            if (text.isNotEmpty) _showAppBarWithTimer();
                          },
                          backgroundColor: Colors.white,
                          calculateInitialZoom: (doc, ctrl, fitZoom, coverZoom) {
                            _pdfFitZoom = fitZoom;
                            if (_currentPdfUrl != null) {
                              final saved = _scrollPositions[_currentPdfUrl!.split('#').first];
                              if (saved != null && saved > 1) {
                                Future.delayed(const Duration(milliseconds: 100), () {
                                  _pdfViewerController?.goToPage(pageNumber: saved.round());
                                });
                              }
                            }
                            return fitZoom * (1.0 + _pdfZoomLevel * 0.25).clamp(0.25, 4.0);
                          },
                          onViewSizeChanged: (viewSize, oldSize, ctrl) {
                            if (_pdfFitZoom > 0) {
                              WidgetsBinding.instance.addPostFrameCallback(
                                  (_) { if (mounted) _applyPdfZoom(); });
                            }
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Double-tap + long-press detector for the auto-hiding app bar
            // (Android + macOS — desktop runs through PointerEvent the same
            // way, so the same gestures toggle the bar with a mouse). The
            // Listener doesn't consume events, so the WebView still gets the
            // input for native text selection.
            if (_autoHideAppBar)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onPagePointerDown,
                  onPointerMove: _onPagePointerMove,
                  onPointerUp: _onPagePointerUp,
                  onPointerCancel: (_) { _longPressTimer?.cancel(); _longPressTimer = null; _pointerDownPos = null; },
                ),
              ),
            // Transparent overlay to unfocus URL bar when tapping the page
            if (_urlBarFocused)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                ),
              ),
            // The WebView's own fullscreen view (Android), under the chips.
            if (_androidFullscreenView != null)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: _androidFullscreenView,
                ),
              ),
            // App bar overlay — auto-hides on Android + macOS, always visible elsewhere
            if ((_showAppBar || !_autoHideAppBar) && !_webFullscreen)
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  bottom: false,
                  child: appBar,
                ),
              ),
            // Find-in-page bar
            if (_showFindBar && !_webFullscreen)
              Positioned(
                top: _showAppBar ? kToolbarHeight + MediaQuery.of(context).padding.top : 0,
                left: 0, right: 0,
                child: Material(
                  elevation: 4,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _findController,
                            autofocus: true,
                            decoration: const InputDecoration(
                              hintText: 'Find in page...',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (q) => _findInPage(q),
                            textInputAction: TextInputAction.search,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                          tooltip: 'Previous',
                          onPressed: () => _findInPage(_findController.text, forward: false),
                        ),
                        IconButton(
                          icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                          tooltip: 'Next',
                          onPressed: () => _findInPage(_findController.text),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          tooltip: 'Close',
                          onPressed: () {
                            setState(() {
                              _showFindBar = false;
                              _findController.clear();
                              _clearFindHighlights();
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Minimized-dialog chips live on the root overlay (see
            // _ensureFloatingChipsOverlay) so they stay on top of any open
            // dialog and can be dragged freely.
            if (_tagCaptureToggleVisible)
              TagCaptureFloatingChip(
                armed: _tagCaptureArmed,
                initialPos: _tagCaptureChipPos,
                onTap: _onCaptureChipTap,
                onHide: () {
                  setState(() {
                    _tagCaptureToggleVisible = false;
                    _tagCaptureArmed = false;
                  });
                  _controller.runJavaScript(
                    'window.__cupitorSetCaptureMode && window.__cupitorSetCaptureMode(false);',
                  );
                },
                onMoved: (pos) => _tagCaptureChipPos = pos,
              ),
            if (_videoNoteEnabled && _videoNoteHasVideo)
              TagCaptureFloatingChip(
                armed: true,
                armedIcon: Icons.edit_note,
                armedColor: Colors.indigo,
                armedBorderColor: const Color(0xFF1A237E),
                // Above the capture chip's default corner so the two never
                // start stacked on each other.
                initialPos: _videoNoteChipPos.dx >= 0
                    ? _videoNoteChipPos
                    : Offset(
                        MediaQuery.of(context).size.width - 64,
                        MediaQuery.of(context).size.height -
                            MediaQuery.of(context).padding.bottom - 208,
                      ),
                onTap: _openVideoNote,
                onHide: () => _setVideoNoteEnabled(false),
                onMoved: (pos) => _videoNoteChipPos = pos,
              ),
            // Over a fullscreen video too, like the other floating buttons.
            if (_studyFsChipEnabled)
              TagCaptureFloatingChip(
                armed: true,
                armedIcon: Icons.fullscreen,
                armedColor: Colors.teal,
                armedBorderColor: const Color(0xFF004D40),
                // Above the video-note button's starting place, so none of
                // the chips start stacked on another.
                initialPos: _studyFsChipPos.dx >= 0
                    ? _studyFsChipPos
                    : Offset(
                        MediaQuery.of(context).size.width - 64,
                        MediaQuery.of(context).size.height -
                            MediaQuery.of(context).padding.bottom - 272,
                      ),
                onTap: _openStudyFullscreen,
                onHide: () => _setStudyFsChipEnabled(false),
                onMoved: (pos) => _studyFsChipPos = pos,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------- YouTube subtitle isolate helpers ----------
// Top-level so they can be passed to `compute()`. The json3 cue blob can hit
// ~1 MB on hour-long videos — parsing on the UI isolate would jank the frame,
// so we hand it off to a background isolate.


/// Parses a YouTube `fmt=json3` caption body into `[{index, start, end, text}]`.
/// Empty / timing-only events are dropped; multi-segment events are flattened
/// by concatenating their `utf8` parts. `start`/`end` are in seconds.
List<Map<String, dynamic>> _parseYtJson3Captions(String body) {
  Map<String, dynamic> root;
  try {
    root = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return const [];
  }
  final events = root['events'];
  if (events is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in events) {
    if (e is! Map) continue;
    final segs = e['segs'];
    if (segs is! List) continue;
    final buf = StringBuffer();
    for (final s in segs) {
      if (s is Map && s['utf8'] is String) buf.write(s['utf8']);
    }
    final text = buf.toString().replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    final tStart = (e['tStartMs'] as num?)?.toDouble() ?? 0;
    final dDur = (e['dDurationMs'] as num?)?.toDouble() ?? 0;
    out.add({
      'index': out.length,
      'start': tStart / 1000.0,
      'end': (tStart + dDur) / 1000.0,
      'text': text,
    });
  }
  return out;
}

/// Fallback parser for YouTube's default (`srv1`) timed-text XML, used when
/// `fmt=json3` comes back empty (happens on some non-English ASR tracks).
/// Shape we accept:
/// ```xml
/// <transcript>
///   <text start="0.42" dur="3.12">Hello &amp;amp; world</text>
///   ...
/// </transcript>
/// ```
/// Returns the same `[{index, start, end, text}]` shape as the json3 parser
/// so the caller path is identical.
List<Map<String, dynamic>> _parseYtTimedTextXml(String body) {
  if (body.isEmpty) return const [];
  // Regex parsing is fine here — the schema is fixed and shallow.
  final re = RegExp(
    r'<text\s+([^>]*?)>([\s\S]*?)<\/text>',
    multiLine: true,
  );
  final out = <Map<String, dynamic>>[];
  for (final m in re.allMatches(body)) {
    final attrs = m.group(1) ?? '';
    final raw = m.group(2) ?? '';
    double parseAttr(String name) {
      final am = RegExp('$name="([^"]*)"').firstMatch(attrs);
      if (am == null) return 0;
      return double.tryParse(am.group(1) ?? '') ?? 0;
    }
    final start = parseAttr('start');
    final dur = parseAttr('dur');
    final text = _decodeXmlEntities(raw).replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    out.add({
      'index': out.length,
      'start': start,
      'end': start + dur,
      'text': text,
    });
  }
  return out;
}

String _decodeXmlEntities(String s) {
  return s
      // Two-pass for nested entities (`&amp;amp;` → `&amp;` → `&`).
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
}

/// Parses a WebVTT caption body into `[{index, start, end, text}]`. Used as
/// a fallback when yt-dlp can't produce json3 (some non-English ASR tracks).
/// Cue format:
/// ```
/// WEBVTT
///
/// 00:00:01.500 --> 00:00:04.000
/// Hello <c.colorE5E5E5>world</c>
/// ```
/// Inline tags (`<c>…</c>`, `<i>`, timestamp tags) are stripped — we only
/// keep the text payload.
List<Map<String, dynamic>> _parseVttCaptions(String body) {
  if (body.isEmpty) return const [];
  final tsRe = RegExp(
    r'(\d{1,2}):(\d{2}):(\d{2})[\.,](\d{1,3})\s+-->\s+'
    r'(\d{1,2}):(\d{2}):(\d{2})[\.,](\d{1,3})',
  );
  final tagRe = RegExp(r'<[^>]*>');
  final lines = body.split(RegExp(r'\r?\n'));
  final out = <Map<String, dynamic>>[];
  var i = 0;
  while (i < lines.length) {
    final m = tsRe.firstMatch(lines[i]);
    if (m == null) { i++; continue; }
    double parseTs(int h, int mm, int s, int ms) =>
        h * 3600 + mm * 60 + s + ms / 1000.0;
    final start = parseTs(
      int.parse(m.group(1)!), int.parse(m.group(2)!),
      int.parse(m.group(3)!), int.parse(m.group(4)!.padRight(3, '0')),
    );
    final end = parseTs(
      int.parse(m.group(5)!), int.parse(m.group(6)!),
      int.parse(m.group(7)!), int.parse(m.group(8)!.padRight(3, '0')),
    );
    i++;
    final buf = StringBuffer();
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      final stripped = lines[i].replaceAll(tagRe, '').trim();
      if (stripped.isNotEmpty) {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(stripped);
      }
      i++;
    }
    final text = buf.toString().trim();
    if (text.isEmpty) continue;
    // De-dupe consecutive identical lines — YouTube's ASR VTT often repeats
    // each cue at finer granularity (rolling karaoke style).
    if (out.isNotEmpty && (out.last['text'] as String) == text) {
      out.last['end'] = end;
      continue;
    }
    out.add({
      'index': out.length,
      'start': start,
      'end': end,
      'text': text,
    });
  }
  return out;
}

/// A small draggable chip shown on the root overlay to represent a minimized
/// dialog. Tap to restore; the trailing "×" closes the dialog entirely.
class _FloatingDraggableChip extends StatefulWidget {
  final Offset startPosition;
  final Size screenSize;
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<Offset>? onPositionChanged;
  const _FloatingDraggableChip({
    super.key,
    required this.startPosition,
    required this.screenSize,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.onClose,
    this.onPositionChanged,
  });
  @override
  State<_FloatingDraggableChip> createState() => _FloatingDraggableChipState();
}

class _FloatingDraggableChipState extends State<_FloatingDraggableChip> {
  late Offset _pos = widget.startPosition;
  bool _dragging = false;
  static const double _kEstimatedWidth = 140;
  static const double _kEstimatedHeight = 44;

  @override
  void didUpdateWidget(_FloatingDraggableChip old) {
    super.didUpdateWidget(old);
    // Re-clamp if the screen rotated and the chip would be off-screen.
    final maxX = widget.screenSize.width - _kEstimatedWidth;
    final maxY = widget.screenSize.height - _kEstimatedHeight;
    if (_pos.dx > maxX || _pos.dy > maxY) {
      _pos = Offset(_pos.dx.clamp(0.0, maxX), _pos.dy.clamp(0.0, maxY));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _dragging = true),
        onPanUpdate: (d) {
          setState(() {
            final nx = (_pos.dx + d.delta.dx).clamp(0.0, widget.screenSize.width - _kEstimatedWidth);
            final ny = (_pos.dy + d.delta.dy).clamp(0.0, widget.screenSize.height - _kEstimatedHeight);
            _pos = Offset(nx, ny);
          });
          widget.onPositionChanged?.call(_pos);
        },
        onPanEnd: (_) => setState(() => _dragging = false),
        // Treat a simple press as restore — onTap, not onPanEnd-without-movement,
        // because GestureDetector resolves them independently.
        onTap: widget.onTap,
        child: Material(
          elevation: _dragging ? 12 : 6,
          color: Theme.of(context).primaryColor,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.icon,
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 90),
                  child: Text(
                    widget.label,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: widget.onClose,
                  customBorder: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, color: Colors.white70, size: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

