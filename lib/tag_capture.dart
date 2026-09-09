import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'speech_hub.dart';
import 'package:url_launcher/url_launcher.dart';
import 'db.dart';
import 'media_store.dart';

/// 16-color palette for new-tag creation / recolor. Fixed swatches —
/// no custom hex picker (kept simple per spec). Order chosen so the
/// most-likely-used hues sit at the front.
const List<String> kTagPalette = [
  '#FFC107', // amber
  '#4CAF50', // green
  '#2196F3', // blue
  '#F44336', // red
  '#9C27B0', // purple
  '#FF9800', // orange
  '#00BCD4', // cyan
  '#795548', // brown
  '#E91E63', // pink
  '#3F51B5', // indigo
  '#009688', // teal
  '#CDDC39', // lime
  '#FF5722', // deep orange
  '#673AB7', // deep purple
  '#FFEB3B', // yellow
  '#607D8B', // blue grey
];

Color _hexColor(String hex) {
  final s = hex.replaceFirst('#', '');
  return Color(int.parse('FF$s', radix: 16));
}

/// Initial payload from JS on capture (or extend re-open). [sentenceId]
/// is the transient JS-side id used for further extend / commit calls.
class CapturePayload {
  final String sentenceId;
  final String text;
  final String prevFp;
  final String nextFp;
  const CapturePayload({
    required this.sentenceId,
    required this.text,
    required this.prevFp,
    required this.nextFp,
  });
}

/// Result of an extend request. [text] is null when the extend hit the
/// block boundary — the sheet greys out the corresponding button.
class ExtendResult {
  final String? text;
  final String prevFp;
  final String nextFp;
  const ExtendResult({required this.text, required this.prevFp, required this.nextFp});
}

/// A media file the user picked in the capture sheet but hasn't yet
/// committed to disk — the ingest into [MediaStore] happens after the
/// sentence row is upserted (so we know its sentence_id).
class PendingMediaAttachment {
  final File file;
  final String originalFilename;
  /// Cached size of [file] in bytes. Populated when the pick lands
  /// (and refreshed when compression swaps the file). Nullable so a
  /// pending item can render before the length() call resolves.
  final int? sizeBytes;
  const PendingMediaAttachment({
    required this.file,
    required this.originalFilename,
    this.sizeBytes,
  });
}

/// A URL attachment the user typed in the capture sheet but hasn't yet
/// been persisted. [kind] is inferred from the URL path extension via
/// [MediaStore.kindFromUrl] so previews render with the right icon.
/// [label] is optional; if the user didn't type one, the caller falls
/// back to the URL itself when displaying filename in the DB row.
class PendingUrlAttachment {
  final String url;
  final String kind; // 'image' | 'audio' | 'video' | 'link'
  final String? label;
  const PendingUrlAttachment({
    required this.url,
    required this.kind,
    this.label,
  });
}

class CaptureSaveResult {
  final String text;
  final String prevFp;
  final String nextFp;
  final List<int> tagIds;
  /// Replacement / mask text. Empty string means "clear the mask if
  /// one existed"; the Dart caller forwards this to the DB upsert.
  final String mask;
  /// True when the user chose to delete the sentence from the sheet's
  /// Delete button. When set, [tagIds] / [mask] / [text] are unused;
  /// the caller should run `deleteSentence(existingDbId)` and clear the
  /// span visuals instead of upserting.
  final bool deleted;
  /// Newly-picked media files to attach after upsert. Empty when the
  /// user didn't touch the Media row (or is deleting).
  final List<PendingMediaAttachment> pendingMedia;
  /// Newly-added URL attachments. Written straight to the DB after
  /// upsert — no file ingest step.
  final List<PendingUrlAttachment> pendingUrls;
  /// Existing `sentence_media.id`s the user removed in the sheet. The
  /// caller runs [CupitorDb.deleteMediaReturningOrphanSha1] on each and
  /// gcs the file when it comes back non-null.
  final List<int> removedMediaIds;
  const CaptureSaveResult({
    required this.text,
    required this.prevFp,
    required this.nextFp,
    required this.tagIds,
    required this.mask,
    this.deleted = false,
    this.pendingMedia = const [],
    this.pendingUrls = const [],
    this.removedMediaIds = const [],
  });
}

/// Show the capture bottom sheet. Returns the save result, or null on
/// cancel (caller then asks JS to clear the temp highlight).
///
/// [preselectedTagIds] / [initialMask] / [extendDisabled] are used by
/// the long-press → edit flow, where the call site already knows the
/// existing tag set + mask and Prev/Next don't apply.
Future<CaptureSaveResult?> showTagCaptureSheet({
  required BuildContext context,
  required CapturePayload initial,
  required int profileId,
  required String surface,
  required String locator,
  required Future<ExtendResult> Function(String direction) onExtendRequested,
  Iterable<int>? preselectedTagIds,
  String? initialMask,
  bool extendDisabled = false,
  int? existingDbId,
  String? speechLocale,
}) {
  return showModalBottomSheet<CaptureSaveResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _TagCaptureSheet(
      initial: initial,
      profileId: profileId,
      surface: surface,
      locator: locator,
      onExtendRequested: onExtendRequested,
      preselectedTagIds: preselectedTagIds,
      initialMask: initialMask,
      extendDisabled: extendDisabled,
      existingDbId: existingDbId,
      speechLocale: speechLocale,
    ),
  );
}

class _TagCaptureSheet extends StatefulWidget {
  final CapturePayload initial;
  final int profileId;
  final String surface;
  final String locator;
  final Future<ExtendResult> Function(String direction) onExtendRequested;
  final Iterable<int>? preselectedTagIds;
  final String? initialMask;
  final bool extendDisabled;
  final int? existingDbId;
  final String? speechLocale;
  const _TagCaptureSheet({
    required this.initial,
    required this.profileId,
    required this.surface,
    required this.locator,
    required this.onExtendRequested,
    this.preselectedTagIds,
    this.initialMask,
    this.extendDisabled = false,
    this.existingDbId,
    this.speechLocale,
  });

  @override
  State<_TagCaptureSheet> createState() => _TagCaptureSheetState();
}

class _TagCaptureSheetState extends State<_TagCaptureSheet> {
  late String _text;
  late String _prevFp;
  late String _nextFp;
  bool _prevAvailable = true;
  bool _nextAvailable = true;
  // Tracks how many sentences are currently in the selection. Starts at
  // 1 (the user tapped exactly one sentence to open the sheet) and is
  // bumped / decremented as Prev/Next/Trim succeed. Trim buttons are
  // enabled only when this exceeds 1.
  int _rangeSize = 1;
  // Auto-scroll the captured-text preview to the end whenever the text
  // grows (Prev/Next) so newly-added content is visible immediately.
  final ScrollController _textScrollCtrl = ScrollController();
  // TextField doesn't auto-scroll its internal viewport when the
  // controller's text is mutated programmatically — only on user-driven
  // input. The dictation flow updates _maskCtrl.text directly, so we
  // drive the mask field's scroll explicitly via this controller.
  final ScrollController _maskScrollCtrl = ScrollController();

  /// Media already in the DB for [widget.existingDbId] (edit flow) —
  /// loaded on init. Empty in fresh-capture flow.
  List<MediaRow> _existingMedia = [];
  /// User-picked files not yet persisted. Ingested into [MediaStore]
  /// after the sentence is upserted so we know its sentence_id.
  final List<PendingMediaAttachment> _pendingMedia = [];
  /// URL attachments the user typed in but not yet persisted. Written
  /// straight to the DB after upsert — no file ingest.
  final List<PendingUrlAttachment> _pendingUrls = [];
  /// [MediaRow.id]s the user removed via the media list's × button.
  /// Applied by the caller after Save via
  /// [CupitorDb.deleteMediaReturningOrphanSha1].
  final Set<int> _removedMediaIds = {};
  /// Compression preset applied to newly-picked images at pick time.
  /// Persisted under `imgCompressionPreset`. Stays as "original" until
  /// the user explicitly changes it, so pre-existing behavior is
  /// unchanged for people who don't care about size.
  ImageCompressionPreset _compressionPreset = ImageCompressionPreset.original;
  /// Total on-disk bytes used by media attached to the current book
  /// (EPUB) or page (web). Refreshed on init, after each save-related
  /// event that changes it, and after a successful pick. URL
  /// attachments don't contribute (they carry no size_bytes).
  int _bookMediaBytes = 0;

  List<TagRow> _allTags = [];
  final Set<int> _selected = {};
  bool _loadingTags = true;

  bool _newTagOpen = false;
  final TextEditingController _newTagCtrl = TextEditingController();
  String _newTagColor = kTagPalette.first;

  // Replacement / mask text. Empty = no mask. Persisted on Save.
  final TextEditingController _maskCtrl = TextEditingController();

  // Voice-input plumbing for the mask field. Listening is gated on the
  // mic button — initialize happens lazily on first tap so the sheet
  // doesn't request permissions you may never need.
  // The one process-wide recognizer. See SpeechHub.
  stt.SpeechToText get _speech => SpeechHub.speech;
  // Our claim on its callbacks, held only while this sheet owns the mic.
  late final SpeechHubListener _speechHubListener = SpeechHubListener(
    onSpeechStatus: _onSpeechStatus,
    onSpeechError: _onSpeechError,
    onSpeechLost: _onSpeechLost,
  );
  bool _speechInitialized = false;
  bool _isListening = false;
  // True while the user wants the mic open. The speech_to_text plugin
  // ends each utterance on its own after a pause; we re-listen() as
  // long as this stays true. Flipped off only by an explicit mic-tap.
  bool _continuousListen = false;
  // Committed transcript: everything that's already turned into a
  // finalResult, prepended with whatever was in the field at listen-
  // start. The TextField visually shows this + the latest partial.
  String _dictatedRunningText = '';
  String? _speechLocale;
  // Watchdog: speech_to_text sometimes gets wedged (UI shows mic active
  // but the engine has silently stopped). Every few seconds we compare
  // our flag against _speech.isListening and force-restart if stale.
  Timer? _micWatchdog;

  // Scope the locale at the BOOK level for EPUBs (epub:<sha>), not the
  // chapter — switching chapters of the same book shouldn't lose the
  // dictation language. Web locators stay per-URL.
  String get _localePrefKey {
    final loc = widget.locator;
    if (widget.surface == 'epub') {
      final firstSep = loc.indexOf(':');
      final secondSep = firstSep < 0 ? -1 : loc.indexOf(':', firstSep + 1);
      final book = secondSep < 0 ? loc : loc.substring(0, secondSep);
      return 'maskSpeechLocale:epub:$book';
    }
    return 'maskSpeechLocale:${widget.surface}:$loc';
  }

  @override
  void initState() {
    super.initState();
    _text = widget.initial.text;
    _prevFp = widget.initial.prevFp;
    _nextFp = widget.initial.nextFp;
    if (widget.initialMask != null) _maskCtrl.text = widget.initialMask!;
    if (widget.extendDisabled) {
      _prevAvailable = false;
      _nextAvailable = false;
    }
    _speechLocale = widget.speechLocale;
    _loadInitial();
    _loadPersistedLocale();
    _loadCompressionPreset();
    _refreshBookMediaBytes();
  }

  /// Returns `(locator, prefixMatch)` for the DB query:
  /// - EPUB: rolls all chapters up under `epub:<book_sha>:` (prefix).
  /// - Web:  the exact page URL (no prefix).
  ({String locator, bool prefixMatch}) get _bookScopeQuery {
    if (widget.surface == 'epub') {
      final loc = widget.locator;
      final firstSep = loc.indexOf(':');
      final secondSep = firstSep < 0 ? -1 : loc.indexOf(':', firstSep + 1);
      final prefix = secondSep < 0 ? loc : loc.substring(0, secondSep + 1);
      return (locator: prefix, prefixMatch: true);
    }
    return (locator: widget.locator, prefixMatch: false);
  }

  Future<void> _loadCompressionPreset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('imgCompressionPreset');
      final p = parseCompressionPreset(raw);
      if (!mounted) return;
      setState(() => _compressionPreset = p);
    } catch (_) { /* stays at default */ }
  }

  Future<void> _persistCompressionPreset(ImageCompressionPreset p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('imgCompressionPreset', encodeCompressionPreset(p));
    } catch (_) {}
  }

  Future<void> _showCompressionPicker() async {
    final picked = await showModalBottomSheet<ImageCompressionPreset>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.compress, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Image compression',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Applied to newly-picked images at pick time. '
                'Original files never touch the store — the compressed copy '
                'is what gets hashed and saved. Non-image attachments and '
                'URL links are unaffected.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).hintColor,
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final entry in kCompressionSpecs.entries)
              RadioListTile<ImageCompressionPreset>(
                title: Text(entry.value.label),
                value: entry.key,
                groupValue: _compressionPreset,
                onChanged: (v) => Navigator.pop(ctx, v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _compressionPreset = picked);
    await _persistCompressionPreset(picked);
  }

  Future<void> _refreshBookMediaBytes() async {
    final q = _bookScopeQuery;
    final n = await CupitorDb.instance.mediaBytesForLocator(
      profileId: widget.profileId,
      surface: widget.surface,
      locator: q.locator,
      prefixMatch: q.prefixMatch,
    );
    if (!mounted) return;
    setState(() => _bookMediaBytes = n);
  }

  Future<void> _loadPersistedLocale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_localePrefKey);
      if (!mounted || stored == null) return;
      // Stored '' means "Auto" — null on the picker.
      final id = stored.isEmpty ? null : stored;
      // Only adopt if it matches one of our curated locales; older
      // builds may have stored values we no longer expose.
      final known = _kSpeechLocales.any((l) => l.id == id);
      if (!known) return;
      setState(() => _speechLocale = id);
    } catch (_) { /* prefs unavailable — fall back to default */ }
  }

  Future<void> _persistLocale(String? id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_localePrefKey, id ?? '');
    } catch (_) { /* best-effort; we already updated UI state */ }
  }

  Future<void> _loadInitial() async {
    final tags = await CupitorDb.instance.listTags(widget.profileId);
    Iterable<int> preselected = const [];
    if (widget.preselectedTagIds != null) {
      preselected = widget.preselectedTagIds!;
    } else {
      final existing = await CupitorDb.instance.sentenceByIdentity(
        profileId: widget.profileId,
        surface: widget.surface,
        locator: widget.locator,
        text: _text,
        prevFp: _prevFp.isEmpty ? null : _prevFp,
        nextFp: _nextFp.isEmpty ? null : _nextFp,
      );
      if (existing != null) {
        preselected = existing.tags.map((t) => t.id);
        if (_maskCtrl.text.isEmpty && (existing.mask ?? '').isNotEmpty) {
          _maskCtrl.text = existing.mask!;
        }
      }
    }
    List<MediaRow> media = const [];
    if (widget.existingDbId != null) {
      media = await CupitorDb.instance.listMediaForSentence(widget.existingDbId!);
    }
    if (!mounted) return;
    setState(() {
      _allTags = tags;
      _selected.addAll(preselected);
      _existingMedia = media;
      _loadingTags = false;
    });
  }

  Future<void> _pickMediaFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: true,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File picker failed: $e')),
      );
      return;
    }
    if (result == null || result.files.isEmpty || !mounted) return;
    // Materialise picks first (so the strip updates immediately), then
    // kick off compression in the background per-item and swap the
    // File reference once each finishes. Compression is a no-op for
    // non-images and for the 'original' preset.
    final added = <PendingMediaAttachment>[];
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      final file = File(path);
      int? size;
      try { size = await file.length(); } catch (_) {}
      final att = PendingMediaAttachment(
        file: file,
        originalFilename: f.name,
        sizeBytes: size,
      );
      added.add(att);
    }
    if (!mounted) return;
    setState(() => _pendingMedia.addAll(added));
    if (_compressionPreset == ImageCompressionPreset.original) return;
    for (final att in added) {
      // Fire-and-forget — each finishes independently. The pick-time
      // preset is captured in the closure; changing the preset after
      // won't retro-compress already-added items.
      final preset = _compressionPreset;
      // ignore: unawaited_futures
      () async {
        final compressed = await maybeCompressImage(
          att.file,
          preset: preset,
          originalFilename: att.originalFilename,
        );
        if (!mounted || identical(compressed, att.file)) return;
        int? newSize;
        try { newSize = await compressed.length(); } catch (_) {}
        if (!mounted) return;
        // Swap the file reference in-place so the chip re-reads the new
        // (smaller) file for its thumbnail + preview. PendingMediaAttachment
        // fields are final, so we replace the whole entry.
        final i = _pendingMedia.indexOf(att);
        if (i < 0) return;
        setState(() {
          _pendingMedia[i] = PendingMediaAttachment(
            file: compressed,
            originalFilename: att.originalFilename,
            sizeBytes: newSize,
          );
        });
      }();
    }
  }

  void _removePending(int index) {
    setState(() => _pendingMedia.removeAt(index));
  }

  void _removeExisting(MediaRow row) {
    setState(() {
      _existingMedia.removeWhere((m) => m.id == row.id);
      _removedMediaIds.add(row.id);
    });
  }

  void _removePendingUrl(int index) {
    setState(() => _pendingUrls.removeAt(index));
  }

  Future<void> _pickUrlAttachment() async {
    final result = await showDialog<PendingUrlAttachment>(
      context: context,
      builder: (_) => const _UrlAttachmentDialog(),
    );
    if (result == null || !mounted) return;
    setState(() => _pendingUrls.add(result));
  }

  Future<void> _openUrlExternally(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No app available to open this URL.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open URL: $e')),
        );
      }
    }
  }

  Future<void> _previewMedia({
    MediaRow? existing,
    PendingMediaAttachment? pending,
    PendingUrlAttachment? pendingUrl,
  }) async {
    if (!mounted) return;
    // URL branch — no file resolution, just show the URL + "Open".
    if (pendingUrl != null || (existing != null && existing.isUrl)) {
      final url = pendingUrl?.url ?? existing!.url!;
      final kind = pendingUrl?.kind ?? existing!.kind;
      final label = pendingUrl?.label?.isNotEmpty == true
          ? pendingUrl!.label!
          : (existing?.filename ?? url);
      await _showUrlPreviewDialog(url: url, kind: kind, label: label);
      return;
    }
    File? file;
    String kind;
    String label;
    if (existing != null) {
      final ext = _extOf(existing.filename);
      file = await MediaStore.instance.resolve(existing.sha1, extension: ext);
      kind = existing.kind;
      label = existing.filename;
    } else if (pending != null) {
      file = pending.file;
      final ext = _extOf(pending.originalFilename);
      kind = MediaStore.kindFromMime(null, ext);
      label = pending.originalFilename;
    } else {
      return;
    }
    if (!mounted) return;
    if (file == null || !await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Media file is missing on disk.')),
      );
      return;
    }
    if (!mounted) return;
    final capturedFile = file;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(ctx).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            if (kind == 'image')
              Padding(
                padding: const EdgeInsets.all(8),
                child: InteractiveViewer(
                  child: Image.file(
                    capturedFile,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Could not display image.'),
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      kind == 'audio' ? Icons.audiotrack : Icons.videocam,
                      size: 64,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      kind == 'audio' ? 'Audio attachment' : 'Video attachment',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'In-app playback not yet supported. The file is stored '
                      'and preserved with the tag.',
                      textAlign: TextAlign.center,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showUrlPreviewDialog({
    required String url,
    required String kind,
    required String label,
  }) async {
    IconData icon;
    switch (kind) {
      case 'image': icon = Icons.image_outlined; break;
      case 'audio': icon = Icons.audiotrack; break;
      case 'video': icon = Icons.videocam_outlined; break;
      default: icon = Icons.link;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'External URL:',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            SelectableText(
              url,
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _openUrlExternally(url);
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open'),
          ),
        ],
      ),
    );
  }

  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  void dispose() {
    _newTagCtrl.dispose();
    _maskCtrl.dispose();
    _textScrollCtrl.dispose();
    _maskScrollCtrl.dispose();
    SpeechHub.release(_speechHubListener);
    _micWatchdog?.cancel();
    // Release the mic so a later voice-input flow (or another app) can
    // grab it. cancel() over stop() — stop fires onResult one last time
    // and we're about to be destroyed.
    _continuousListen = false;
    // Unconditional: the toggle-off path uses stop(), which arms the plugin's
    // 2 s timer to promote the last partial. Closing the sheet inside that
    // window would otherwise let the promoted result run our onResult and
    // write to an already-disposed controller. cancel() kills that timer and
    // is a no-op when nothing is running.
    _speech.cancel().catchError((_) {});
    super.dispose();
  }

  void _scrollCapturedTextToEnd() {
    if (!_textScrollCtrl.hasClients) return;
    // Defer to next frame so the SelectableText has laid out with the
    // new content and maxScrollExtent reflects it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_textScrollCtrl.hasClients) return;
      _textScrollCtrl.animateTo(
        _textScrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _scrollMaskFieldToEnd() {
    if (!_maskScrollCtrl.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_maskScrollCtrl.hasClients) return;
      _maskScrollCtrl.jumpTo(_maskScrollCtrl.position.maxScrollExtent);
    });
  }

  Future<void> _toggleMaskMic() async {
    if (_isListening || _continuousListen) {
      _continuousListen = false;
      _micWatchdog?.cancel();
      _micWatchdog = null;
      try { await _speech.stop(); } catch (_) {}
      // Field text is already up-to-date (every finalResult committed
      // into _dictatedRunningText). Nothing else to flush.
      if (mounted) setState(() => _isListening = false);
      return;
    }
    // speech_to_text is a singleton on the native side: even though this
    // is a separate SpeechToText instance from the main voice-input one,
    // the engine itself is shared. Release any prior session first so
    // listen() doesn't collide ("speech already started" / no-op).
    try { await _speech.stop(); } catch (_) {}
    try { await _speech.cancel(); } catch (_) {}
    // Init and callbacks go through SpeechHub, not initialize() directly:
    // the plugin only ever honours the first registration in the process, so
    // whichever screen the user opened first would otherwise own the
    // callbacks and this loop would never be told an utterance ended.
    _speechInitialized = await SpeechHub.ensureInitialized();
    if (!_speechInitialized) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition unavailable.')),
        );
      }
      return;
    }
    // Seed the running transcript with whatever's already typed so new
    // dictation appends instead of overwriting.
    _dictatedRunningText = _maskCtrl.text;
    _continuousListen = true;
    setState(() => _isListening = true);
    await _startMaskListen();
    _startMicWatchdog();
  }

  /// Continuous loop: the plugin ends each utterance after a pause. While the
  /// user still wants the mic open, kick off a new listen() session.
  ///
  /// 'done' only — 'notListening' arrives before the engine's final result,
  /// so restarting on it resets the plugin's final-result timer and destroys
  /// the utterance the user just spoke. The plugin always delivers 'done'
  /// eventually, including when nothing was heard.
  void _onSpeechStatus(String status) {
    if (status != 'done') return;
    if (_continuousListen && mounted) _restartMaskListen();
  }

  /// Don't tear down — just relaunch if the user still wants continuous
  /// capture. Common errors are transient (e.g. "no-speech-detected").
  void _onSpeechError(SpeechRecognitionError error) {
    if (_continuousListen && mounted) {
      _restartMaskListen();
    } else if (mounted && _isListening) {
      setState(() => _isListening = false);
    }
  }

  /// Another feature took the mic. Stop the loop and reset the button rather
  /// than sitting lit with no events coming.
  void _onSpeechLost() {
    _continuousListen = false;
    _micWatchdog?.cancel();
    _micWatchdog = null;
    if (mounted && _isListening) setState(() => _isListening = false);
  }

  void _startMicWatchdog() {
    _micWatchdog?.cancel();
    // Every 4 seconds, check the plugin's view of reality. If we think
    // we're listening but it disagrees and we missed the 'done' callback
    // (a known wedge case on Android), restart explicitly.
    _micWatchdog = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_continuousListen) return;
      if (!_speech.isListening) {
        _restartMaskListen();
      }
    });
  }

  Future<void> _startMaskListen() async {
    try {
      SpeechHub.acquire(_speechHubListener);
      await _speech.listen(
        localeId: _speechLocale,
        partialResults: true,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 30),
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (result.finalResult) {
            // Commit this utterance to the running transcript.
            if (words.isNotEmpty) {
              final sep = _dictatedRunningText.isEmpty ||
                      _dictatedRunningText.endsWith(' ')
                  ? ''
                  : ' ';
              _dictatedRunningText = '$_dictatedRunningText$sep$words';
            }
            _maskCtrl.text = _dictatedRunningText;
          } else {
            // Show partial appended after the committed text so the
            // user sees the dictation streaming live.
            final sep = _dictatedRunningText.isEmpty ||
                    _dictatedRunningText.endsWith(' ')
                ? ''
                : ' ';
            _maskCtrl.text = '$_dictatedRunningText$sep$words';
          }
          _maskCtrl.selection = TextSelection.collapsed(
            offset: _maskCtrl.text.length,
          );
          _scrollMaskFieldToEnd();
        },
      );
    } catch (_) {
      // Listen failed to start. If we still want continuous, schedule a
      // retry; otherwise reset UI state.
      if (_continuousListen && mounted) {
        _restartMaskListen();
      } else if (mounted) {
        setState(() => _isListening = false);
      }
    }
  }

  void _restartMaskListen() {
    // Small delay so the plugin's previous session fully tears down
    // before we kick off the next one. Matches the pattern used by the
    // main app's continuous voice capture.
    Future.delayed(const Duration(milliseconds: 200), () async {
      if (!mounted || !_continuousListen) return;
      await _startMaskListen();
    });
  }

  Future<void> _extend(String direction) async {
    final res = await widget.onExtendRequested(direction);
    if (!mounted) return;
    setState(() {
      if (res.text == null) {
        if (direction == 'prev') _prevAvailable = false;
        if (direction == 'next') _nextAvailable = false;
      } else {
        _text = res.text!;
        _prevFp = res.prevFp;
        _nextFp = res.nextFp;
        _rangeSize += 1;
        // Reaching a new sentence on one end un-greys the opposite
        // boundary if it had previously fired.
        if (direction == 'prev') _nextAvailable = true;
        if (direction == 'next') _prevAvailable = true;
      }
    });
    _scrollCapturedTextToEnd();
  }

  Future<void> _trim(String side) async {
    // side: 'start' | 'end' — mapped to JS direction names.
    final direction = side == 'start' ? 'trimStart' : 'trimEnd';
    final res = await widget.onExtendRequested(direction);
    if (!mounted) return;
    if (res.text == null) {
      // Boundary reached — shouldn't happen since we gate the buttons
      // on _rangeSize > 1, but stay defensive.
      return;
    }
    setState(() {
      _text = res.text!;
      _prevFp = res.prevFp;
      _nextFp = res.nextFp;
      if (_rangeSize > 1) _rangeSize -= 1;
      // Trimming makes Prev/Next available again on the trimmed side —
      // we now have a known neighbouring sentence to reach.
      if (side == 'start') _prevAvailable = true;
      if (side == 'end') _nextAvailable = true;
    });
    _scrollCapturedTextToEnd();
  }

  Future<void> _createNewTag() async {
    final name = _newTagCtrl.text.trim();
    if (name.isEmpty) return;
    final created = await CupitorDb.instance.createTag(widget.profileId, name, _newTagColor);
    if (!mounted) return;
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tag "$name" already exists')),
      );
      return;
    }
    setState(() {
      _allTags = List.of(_allTags)..add(created);
      _selected.add(created.id);
      _newTagOpen = false;
      _newTagCtrl.clear();
      _newTagColor = kTagPalette.first;
    });
  }

  void _save() {
    Navigator.of(context).pop(CaptureSaveResult(
      text: _text,
      prevFp: _prevFp,
      nextFp: _nextFp,
      tagIds: _selected.toList(),
      mask: _maskCtrl.text.trim(),
      pendingMedia: List.of(_pendingMedia),
      pendingUrls: List.of(_pendingUrls),
      removedMediaIds: _removedMediaIds.toList(),
    ));
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete tagged sentence?'),
        content: const Text(
          'The sentence row, its tags, and any mask text will be removed. '
          'The book or webpage text itself is untouched.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop(CaptureSaveResult(
      text: _text,
      prevFp: _prevFp,
      nextFp: _nextFp,
      tagIds: const [],
      mask: '',
      deleted: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Tag this sentence', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  controller: _textScrollCtrl,
                  child: SelectableText(_text, style: theme.textTheme.bodyMedium),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _prevAvailable ? () => _extend('prev') : null,
                      icon: const Icon(Icons.chevron_left, size: 18),
                      label: const Text('Prev'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _nextAvailable ? () => _extend('next') : null,
                      icon: const Icon(Icons.chevron_right, size: 18),
                      label: const Text('Next'),
                    ),
                  ),
                ],
              ),
              if (!widget.extendDisabled) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _rangeSize > 1 ? () => _trim('start') : null,
                        icon: const Icon(Icons.first_page, size: 18),
                        label: const Text('Drop first'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _rangeSize > 1 ? () => _trim('end') : null,
                        icon: const Icon(Icons.last_page, size: 18),
                        label: const Text('Drop last'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text('Mask / replacement (optional)',
                        style: theme.textTheme.titleSmall),
                  ),
                  _SpeechLocalePicker(
                    selected: _speechLocale,
                    enabled: !_isListening,
                    onChanged: (id) {
                      setState(() => _speechLocale = id);
                      _persistLocale(id);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _maskCtrl,
                scrollController: _maskScrollCtrl,
                decoration: InputDecoration(
                  hintText: 'Shown in place of the sentence when "Show masks" is on',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: _isListening ? theme.colorScheme.error : null,
                    ),
                    tooltip: _isListening ? 'Stop dictation' : 'Dictate mask',
                    onPressed: _toggleMaskMic,
                  ),
                ),
                minLines: 1,
                maxLines: 4,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text('Media', style: theme.textTheme.titleSmall)),
                  Text(
                    () {
                      final n = _existingMedia.length + _pendingMedia.length + _pendingUrls.length;
                      return n == 0 ? 'none' : '$n attached';
                    }(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: (_existingMedia.isEmpty && _pendingMedia.isEmpty && _pendingUrls.isEmpty)
                          ? theme.hintColor
                          : theme.colorScheme.primary,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune, size: 18),
                    tooltip: 'Image compression',
                    visualDensity: VisualDensity.compact,
                    onPressed: _showCompressionPicker,
                  ),
                ],
              ),
              // Book-wide media footprint. Shown even at 0 B so the
              // number becomes familiar and the user notices growth.
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.storage_outlined, size: 12, color: theme.hintColor),
                    const SizedBox(width: 4),
                    Text(
                      widget.surface == 'epub'
                          ? 'Book media: ${formatBytes(_bookMediaBytes)}'
                          : 'Page media: ${formatBytes(_bookMediaBytes)}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                    const Spacer(),
                    Text(
                      'New images: ${kCompressionSpecs[_compressionPreset]!.label}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              _MediaStrip(
                existing: _existingMedia,
                pending: _pendingMedia,
                pendingUrls: _pendingUrls,
                onAdd: _pickMediaFile,
                onAddUrl: _pickUrlAttachment,
                onRemoveExisting: _removeExisting,
                onRemovePending: _removePending,
                onRemovePendingUrl: _removePendingUrl,
                onPreviewExisting: (m) => _previewMedia(existing: m),
                onPreviewPending: (p) => _previewMedia(pending: p),
                onPreviewPendingUrl: (p) => _previewMedia(pendingUrl: p),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text('Tags', style: theme.textTheme.titleSmall)),
                  Text(
                    _selected.isEmpty
                        ? 'none selected'
                        : '${_selected.length} selected',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _selected.isEmpty ? theme.hintColor : theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_loadingTags)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _allTags.map((t) {
                          final sel = _selected.contains(t.id);
                          final tagColor = _hexColor(t.color);
                          return FilterChip(
                            label: Text(
                              t.name,
                              style: TextStyle(
                                fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                                color: sel ? theme.colorScheme.onSurface : theme.hintColor,
                              ),
                            ),
                            selected: sel,
                            // Show the checkmark on selected chips so the
                            // on/off state reads at a glance — the alpha
                            // shift alone is too subtle on many displays.
                            checkmarkColor: theme.colorScheme.onSurface,
                            backgroundColor: Colors.transparent,
                            selectedColor: tagColor.withValues(alpha: 0.55),
                            side: BorderSide(
                              color: tagColor,
                              width: sel ? 2 : 1,
                            ),
                            onSelected: (v) => setState(() {
                              if (v) {
                                _selected.add(t.id);
                              } else {
                                _selected.remove(t.id);
                              }
                            }),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    avatar: const Icon(Icons.add, size: 16),
                    label: const Text('New tag'),
                    onPressed: () => setState(() => _newTagOpen = !_newTagOpen),
                  ),
                ),
              ],
              if (_newTagOpen) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _newTagCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'New tag name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _createNewTag(),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: kTagPalette.map((hex) {
                    final sel = _newTagColor == hex;
                    return GestureDetector(
                      onTap: () => setState(() => _newTagColor = hex),
                      child: Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          color: _hexColor(hex),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: sel ? theme.colorScheme.onSurface : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _newTagOpen = false;
                        _newTagCtrl.clear();
                      }),
                      child: const Text('Cancel'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _createNewTag,
                      child: const Text('Add tag'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  if (widget.existingDbId != null)
                    TextButton.icon(
                      onPressed: _confirmDelete,
                      icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                      label: Text(
                        'Delete',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }
}

/// Curated locales for the mask-text speech input. `id == null` means
/// "device default" — speech_to_text picks the system locale.
/// Horizontal strip of media chips shown inside the capture sheet.
/// Renders existing DB rows and freshly-picked pending files side by
/// side, plus a "+ Add" chip at the end. Tap → preview; long-press or
/// the trailing × → remove.
class _MediaStrip extends StatelessWidget {
  final List<MediaRow> existing;
  final List<PendingMediaAttachment> pending;
  final List<PendingUrlAttachment> pendingUrls;
  final VoidCallback onAdd;
  final VoidCallback onAddUrl;
  final void Function(MediaRow) onRemoveExisting;
  final void Function(int) onRemovePending;
  final void Function(int) onRemovePendingUrl;
  final void Function(MediaRow) onPreviewExisting;
  final void Function(PendingMediaAttachment) onPreviewPending;
  final void Function(PendingUrlAttachment) onPreviewPendingUrl;
  const _MediaStrip({
    required this.existing,
    required this.pending,
    required this.pendingUrls,
    required this.onAdd,
    required this.onAddUrl,
    required this.onRemoveExisting,
    required this.onRemovePending,
    required this.onRemovePendingUrl,
    required this.onPreviewExisting,
    required this.onPreviewPending,
    required this.onPreviewPendingUrl,
  });

  IconData _iconFor(String kind, {bool isUrl = false}) {
    // URL attachments get a link decoration on top of the kind icon —
    // just switch to Icons.link when the kind is a generic 'link' or
    // there's no media inference to make.
    if (isUrl && (kind == 'link' || kind.isEmpty)) return Icons.link;
    switch (kind) {
      case 'image': return Icons.image_outlined;
      case 'audio': return Icons.audiotrack;
      case 'video': return Icons.videocam_outlined;
      default: return Icons.link;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 84,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final m in existing)
            _MediaChip(
              icon: _iconFor(m.kind, isUrl: m.isUrl),
              label: m.filename,
              subLabel: m.isUrl
                  ? 'url'
                  : (m.sizeBytes != null
                      ? formatBytes(m.sizeBytes!)
                      : m.kind),
              isUrl: m.isUrl,
              onTap: () => onPreviewExisting(m),
              onRemove: () => onRemoveExisting(m),
              imageFileFuture: (m.kind == 'image' && !m.isUrl)
                  ? MediaStore.instance.resolve(
                      m.sha1,
                      extension: _extOfName(m.filename),
                    )
                  : null,
            ),
          for (int i = 0; i < pending.length; i++)
            _MediaChip(
              icon: _iconFor(MediaStore.kindFromMime(null, _extOfName(pending[i].originalFilename))),
              label: pending[i].originalFilename,
              subLabel: pending[i].sizeBytes != null
                  ? '${formatBytes(pending[i].sizeBytes!)} · new'
                  : 'new',
              isUrl: false,
              onTap: () => onPreviewPending(pending[i]),
              onRemove: () => onRemovePending(i),
              imageFileFuture: _isImageExt(pending[i].originalFilename)
                  ? Future.value(pending[i].file)
                  : null,
            ),
          for (int i = 0; i < pendingUrls.length; i++)
            _MediaChip(
              icon: _iconFor(pendingUrls[i].kind, isUrl: true),
              label: pendingUrls[i].label?.isNotEmpty == true
                  ? pendingUrls[i].label!
                  : pendingUrls[i].url,
              subLabel: 'url · new',
              isUrl: true,
              onTap: () => onPreviewPendingUrl(pendingUrls[i]),
              onRemove: () => onRemovePendingUrl(i),
              imageFileFuture: null,
            ),
          // "+ File" chip
          _AddChip(icon: Icons.add_photo_alternate_outlined, label: 'File', onTap: onAdd),
          // "+ URL" chip
          _AddChip(icon: Icons.add_link, label: 'URL', onTap: onAddUrl),
          // Trailing spacer to give the last chip breathing room.
          SizedBox(width: theme.visualDensity.horizontal + 4),
        ],
      ),
    );
  }

  static String _extOfName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static bool _isImageExt(String name) {
    const set = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};
    return set.contains(_extOfName(name));
  }
}

class _AddChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _AddChip({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 84,
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _MediaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subLabel;
  final bool isUrl;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  /// If non-null, resolves to the on-disk file we should render as a
  /// thumbnail (image attachments only). Null for A/V — the icon shows.
  final Future<File?>? imageFileFuture;
  const _MediaChip({
    required this.icon,
    required this.label,
    required this.subLabel,
    required this.isUrl,
    required this.onTap,
    required this.onRemove,
    required this.imageFileFuture,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 8),
      width: 96,
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          Positioned.fill(
            child: InkWell(
              onTap: onTap,
              child: imageFileFuture != null
                  ? FutureBuilder<File?>(
                      future: imageFileFuture,
                      builder: (_, snap) {
                        final f = snap.data;
                        if (f == null) {
                          return Center(child: Icon(icon, color: theme.colorScheme.primary));
                        }
                        return Image.file(
                          f,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Center(
                            child: Icon(icon, color: theme.colorScheme.primary),
                          ),
                        );
                      },
                    )
                  : Center(child: Icon(icon, size: 36, color: theme.colorScheme.primary)),
            ),
          ),
          // Filename overlay along the bottom, plus a size line so the
          // user sees the on-disk cost per item (post-compression when
          // the file was reduced).
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              color: Colors.black.withValues(alpha: 0.55),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                  Text(
                    subLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 9),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0, right: 0,
            child: InkWell(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(8)),
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
          // URL-source badge in the top-left so the user can distinguish
          // linked-out media from local at a glance.
          if (isUrl)
            Positioned(
              top: 0, left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.only(bottomRight: Radius.circular(8)),
                ),
                child: const Icon(Icons.link, size: 12, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// Prompts the user for a URL and optional label. Returned as a
/// [PendingUrlAttachment] with kind inferred from the path extension.
class _UrlAttachmentDialog extends StatefulWidget {
  const _UrlAttachmentDialog();

  @override
  State<_UrlAttachmentDialog> createState() => _UrlAttachmentDialogState();
}

class _UrlAttachmentDialogState extends State<_UrlAttachmentDialog> {
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _labelCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _urlCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Enter a URL.');
      return;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'That doesn\'t look like a valid URL (e.g. https://…).');
      return;
    }
    final label = _labelCtrl.text.trim();
    Navigator.of(context).pop(PendingUrlAttachment(
      url: raw,
      kind: MediaStore.kindFromUrl(raw),
      label: label.isEmpty ? null : label,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Attach URL'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _urlCtrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'URL',
              hintText: 'https://example.com/photo.jpg',
              border: const OutlineInputBorder(),
              errorText: _error,
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _labelCtrl,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
              hintText: 'What is this?',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Attach'),
        ),
      ],
    );
  }
}

const List<({String? id, String label})> _kSpeechLocales = [
  (id: null, label: 'Auto'),
  (id: 'en-US', label: 'English (US)'),
  (id: 'en-GB', label: 'English (UK)'),
  (id: 'sv-SE', label: 'Swedish'),
  (id: 'es-ES', label: 'Spanish'),
  (id: 'fr-FR', label: 'French'),
  (id: 'de-DE', label: 'German'),
  (id: 'it-IT', label: 'Italian'),
  (id: 'pt-BR', label: 'Portuguese (BR)'),
  (id: 'nl-NL', label: 'Dutch'),
  (id: 'da-DK', label: 'Danish'),
  (id: 'nb-NO', label: 'Norwegian'),
  (id: 'fi-FI', label: 'Finnish'),
  (id: 'ru-RU', label: 'Russian'),
  (id: 'hi-IN', label: 'Hindi'),
  (id: 'ja-JP', label: 'Japanese'),
  (id: 'zh-CN', label: 'Chinese (simplified)'),
];

class _SpeechLocalePicker extends StatelessWidget {
  final String? selected;
  final bool enabled;
  final ValueChanged<String?> onChanged;
  const _SpeechLocalePicker({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selectedLabel = _kSpeechLocales
        .firstWhere(
          (l) => l.id == selected,
          orElse: () => _kSpeechLocales.first,
        )
        .label;
    return PopupMenuButton<String?>(
      enabled: enabled,
      tooltip: 'Dictation language',
      onSelected: onChanged,
      itemBuilder: (ctx) => [
        for (final l in _kSpeechLocales)
          PopupMenuItem<String?>(
            value: l.id,
            child: Row(
              children: [
                if (l.id == selected)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(l.label),
              ],
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.language, size: 16),
          const SizedBox(width: 4),
          Text(selectedLabel, style: Theme.of(context).textTheme.bodySmall),
          const Icon(Icons.arrow_drop_down, size: 16),
        ],
      ),
    );
  }
}

/// Draggable circular toggle shown over the WebView when the user has
/// enabled "Tag sentences" from the Tools drawer. Tap = arm/disarm
/// next-word-tap capture. Long-press = hide (re-enable from Tools).
class TagCaptureFloatingChip extends StatefulWidget {
  final bool armed;
  final Offset initialPos;
  final VoidCallback onTap;
  final VoidCallback onHide;
  final void Function(Offset) onMoved;
  /// Icon shown when the chip is armed. Defaults to the tag icon.
  final IconData armedIcon;
  /// Icon shown when the chip is idle.
  final IconData idleIcon;
  /// Bubble color when armed. Defaults to red (tag mode). Callers that
  /// re-use the chip for a different role (e.g. playlist capture) pass
  /// their own colour so the two chips can co-exist on screen.
  final Color armedColor;
  final Color idleColor;
  final Color armedBorderColor;
  final Color idleBorderColor;
  const TagCaptureFloatingChip({
    super.key,
    required this.armed,
    required this.initialPos,
    required this.onTap,
    required this.onHide,
    required this.onMoved,
    this.armedIcon = Icons.label,
    this.idleIcon = Icons.label_outline,
    this.armedColor = Colors.red,
    this.idleColor = const Color(0xFFE0E0E0),
    this.armedBorderColor = const Color(0xFFB71C1C),
    this.idleBorderColor = const Color(0xFF757575),
  });

  @override
  State<TagCaptureFloatingChip> createState() => _TagCaptureFloatingChipState();
}

class _TagCaptureFloatingChipState extends State<TagCaptureFloatingChip> {
  static const double _size = 48;
  Offset? _pos;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    _pos ??= widget.initialPos.dx < 0
        ? Offset(size.width - _size - 16, size.height - _size - pad.bottom - 96)
        : widget.initialPos;
    return Positioned(
      left: _pos!.dx,
      top: _pos!.dy,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onHide,
        onPanUpdate: (d) {
          setState(() {
            _pos = Offset(
              (_pos!.dx + d.delta.dx).clamp(0, size.width - _size),
              (_pos!.dy + d.delta.dy).clamp(pad.top, size.height - _size - pad.bottom),
            );
          });
          widget.onMoved(_pos!);
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.armed ? widget.armedColor : widget.idleColor,
              border: Border.all(
                color: widget.armed ? widget.armedBorderColor : widget.idleBorderColor,
                width: 2,
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 2)),
              ],
            ),
            child: Icon(
              widget.armed ? widget.armedIcon : widget.idleIcon,
              color: widget.armed ? Colors.white : Colors.grey.shade800,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
