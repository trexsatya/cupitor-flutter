import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'book_transfer.dart';
import 'db.dart';
import 'epub_reader.dart' show EpubLibrary, EpubLibraryEntry;
import 'media_store.dart';

/// Storage overview + per-book breakdown.
///
/// Shows what Cupitor is holding on to (DB, media store, EPUB library)
/// and lets the user drill down per book to export / delete / see
/// stats. Orphan-file cleanup is exposed once at the top so the whole
/// media store can be swept in a single tap.
///
/// The screen is not profile-scoped — storage is shared across
/// profiles, and export/import round-trip every profile's data.
class MemoryManagerScreen extends StatefulWidget {
  const MemoryManagerScreen({super.key});

  @override
  State<MemoryManagerScreen> createState() => _MemoryManagerScreenState();
}

class _MemoryManagerScreenState extends State<MemoryManagerScreen> {
  bool _loading = true;
  int _dbBytes = 0;
  int _mediaStoreBytes = 0;
  int _mediaFileCount = 0;
  int _orphanCount = 0;
  int _danglingRowCount = 0;
  int _libraryBytes = 0;
  int _voiceBytes = 0;
  int _voiceFileCount = 0;
  List<BookMemoryStat> _bookStats = const [];
  Map<String, EpubLibraryEntry> _libraryByKey = const {};
  bool _busy = false;

  /// User-recorded voice clips from the dialog1 manual-card editor.
  /// Backing store is `<app_documents>/manual_audio/<id>.<ext>` — files
  /// are keyed by JS-supplied ids, so this Dart side has no view into
  /// which cards still reference them.
  static const String _voiceDirName = 'manual_audio';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    // Fire everything off in parallel — none depend on each other.
    final dbBytesFut = CupitorDb.instance.dbFileBytes();
    final libFut = EpubLibrary.load();
    final filesFut = MediaStore.instance.listAllFiles();
    final referencedFut = CupitorDb.instance.referencedFileSha1s();
    final statsFut = CupitorDb.instance.perBookMemoryStats();
    final voiceFut = _scanVoiceRecordings();

    final dbBytes = await dbBytesFut;
    final lib = await libFut;
    final files = await filesFut;
    final referenced = await referencedFut;
    final stats = await statsFut;
    final voice = await voiceFut;

    // Sum on-disk bytes for every file in the store. `File.length()`
    // is async; loop serially — most stores are small.
    var mediaBytes = 0;
    var orphan = 0;
    for (final e in files.entries) {
      try {
        mediaBytes += await e.value.length();
      } catch (_) {}
      if (!referenced.contains(e.key)) orphan++;
    }
    // Dangling: rows referencing SHA-1s not on disk. Counted so Clean
    // can advertise both directions of the reconciliation.
    final onDisk = files.keys.toSet();
    var dangling = 0;
    for (final sha in referenced) {
      if (!onDisk.contains(sha)) dangling++;
    }
    // Sum library bytes.
    var libBytes = 0;
    final byKey = <String, EpubLibraryEntry>{};
    for (final e in lib.entries) {
      byKey[e.key] = e;
      try {
        final f = File(e.path);
        if (await f.exists()) libBytes += await f.length();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _dbBytes = dbBytes;
      _mediaStoreBytes = mediaBytes;
      _mediaFileCount = files.length;
      _orphanCount = orphan;
      _danglingRowCount = dangling;
      _libraryBytes = libBytes;
      _voiceBytes = voice.bytes;
      _voiceFileCount = voice.count;
      _bookStats = stats;
      _libraryByKey = byKey;
      _loading = false;
    });
  }

  /// Sum bytes + file count under `<app_documents>/manual_audio/`. The
  /// dialog1 audio bridge writes each recorded clip there; we can't
  /// reconcile against ownership (JS localStorage owns the card→clip
  /// map, not the DB) so this is a pure filesystem walk.
  Future<({int bytes, int count})> _scanVoiceRecordings() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$_voiceDirName');
      if (!await dir.exists()) return (bytes: 0, count: 0);
      var bytes = 0;
      var count = 0;
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        count++;
        try {
          bytes += await entry.length();
        } catch (_) {}
      }
      return (bytes: bytes, count: count);
    } catch (_) {
      return (bytes: 0, count: 0);
    }
  }

  /// Reconcile the media store in both directions:
  /// - delete files not referenced by any DB row (orphan files)
  /// - delete DB rows referencing files not on disk (dangling refs)
  /// After Clean, every row has a file and every file has a row.
  Future<void> _cleanOrphans() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Snapshot once so both passes see the same view.
      final referenced = await CupitorDb.instance.referencedFileSha1s();
      final onDiskFiles = await MediaStore.instance.listAllFiles();
      final onDiskShas = onDiskFiles.keys.toSet();

      final filesRemoved = await MediaStore.instance.deleteOrphans(referenced);
      final rowsRemoved = await CupitorDb.instance.deleteMediaRowsForMissingFiles(onDiskShas);

      if (!mounted) return;
      final parts = <String>[
        '$filesRemoved orphan file${filesRemoved == 1 ? '' : 's'}',
        '$rowsRemoved dangling row${rowsRemoved == 1 ? '' : 's'}',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cleaned: ${parts.join(' · ')}')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<void> _exportBook(BookMemoryStat stat) async {
    if (_busy) return;
    final entry = _libraryByKey[stat.bookKey];
    if (entry == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
          'Book file not in library on this device — cannot export.',
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
    setState(() => _busy = true);
    try {
      final bytes = await BookExporter.buildBundle(
        bookKey: stat.bookKey,
        epubFile: file,
      );
      final suggestedName = await BookExporter.defaultFileNameForBook(stat.bookKey);
      if (!mounted) return;
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Cupitor bundle',
        fileName: suggestedName,
        bytes: bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          savedPath == null
              ? 'Export cancelled'
              : 'Exported: $savedPath',
        )),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importBundle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      final path = res?.files.single.path;
      if (path == null) return;
      final imported = await BookImporter.importBundle(
        zipFile: File(path),
      );
      if (!mounted) return;
      final verb = imported.replacedExisting ? 'Replaced' : 'Imported';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          '$verb "${imported.title}" — ${imported.sentencesImported} sentences, '
          '${imported.tagsMappedOrCreated} tags across '
          '${imported.profilesTouched} profile${imported.profilesTouched == 1 ? '' : 's'}',
        )),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<void> _deleteBookData(BookMemoryStat stat) async {
    if (_busy) return;
    final title = _libraryByKey[stat.bookKey]?.title ?? stat.bookKey;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete book data?'),
        content: Text(
          '"$title": remove ${stat.sentenceCount} tagged sentence(s) and '
          '${stat.mediaCount} media attachment(s) across every profile. '
          'Playlists that include this book\'s sentences are cleared too. '
          'Tags themselves are preserved (they live across books). '
          'The EPUB file on disk is NOT deleted — remove it from the '
          'library separately if you want that too.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await CupitorDb.instance.deleteBookData(
        profileId: CupitorDb.defaultProfileId, // param ignored — wipe is per-book
        bookKey: stat.bookKey,
      );
      // Sweep newly-orphaned media files.
      final referenced = await CupitorDb.instance.referencedFileSha1s();
      await MediaStore.instance.deleteOrphans(referenced);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cleared data for "$title"')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _dbBytes + _mediaStoreBytes + _libraryBytes + _voiceBytes;
    final needsClean = _orphanCount > 0 || _danglingRowCount > 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'Import book bundle',
            onPressed: _busy ? null : _importBundle,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _headerCard(theme, total),
                _storageRow(theme, 'EPUB library', _libraryBytes,
                    subtitle: '${_libraryByKey.length} book(s)',
                    icon: Icons.menu_book_outlined),
                _storageRow(theme, 'Media store', _mediaStoreBytes,
                    subtitle: '$_mediaFileCount file(s) · $_orphanCount orphan(s)'
                        '${_danglingRowCount > 0 ? ' · $_danglingRowCount dangling' : ''}',
                    icon: Icons.perm_media_outlined,
                    trailing: needsClean
                        ? TextButton(
                            onPressed: _busy ? null : _cleanOrphans,
                            child: const Text('Clean'),
                          )
                        : null),
                _storageRow(theme, 'Voice recordings', _voiceBytes,
                    subtitle: '$_voiceFileCount clip(s) from manual cards',
                    icon: Icons.mic_none_outlined,
                    trailing: _voiceFileCount == 0
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: _voiceFileCount == 0
                        ? null
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const VoiceRecordingsScreen(),
                              ),
                            );
                            if (mounted) await _reload();
                          }),
                _storageRow(theme, 'Database', _dbBytes,
                    subtitle: 'sqlite (tags, sentences, playlists…)',
                    icon: Icons.storage_outlined),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Per book (all profiles)', style: theme.textTheme.titleSmall),
                ),
                if (_bookStats.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No tagged data for any book yet.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                  )
                else
                  for (final s in _bookStats) _bookCard(theme, s),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _headerCard(ThemeData theme, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.memory, size: 32, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total on-device storage',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                    Text(formatBytes(total), style: theme.textTheme.headlineSmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _storageRow(
    ThemeData theme,
    String label,
    int bytes, {
    required String subtitle,
    required IconData icon,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Row(
        children: [
          Expanded(child: Text(label)),
          Text(formatBytes(bytes),
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _bookCard(ThemeData theme, BookMemoryStat s) {
    final entry = _libraryByKey[s.bookKey];
    final title = entry?.title ?? '(book not in library)';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(formatBytes(s.mediaBytes),
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${s.sentenceCount} sentences · ${s.tagCount} tags · '
              '${s.mediaCount} media',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (entry != null)
                  TextButton.icon(
                    onPressed: _busy ? null : () => _exportBook(s),
                    icon: const Icon(Icons.file_upload, size: 18),
                    label: const Text('Export'),
                  ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _busy ? null : () => _deleteBookData(s),
                  icon: Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                  label: Text('Delete data', style: TextStyle(color: theme.colorScheme.error)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Voice-recording browser. Lists every clip under
/// `<app_documents>/manual_audio/` so the user can delete them
/// individually or all at once. Cannot show *which* manual card owns
/// a clip — that mapping lives in the dialog1 WebView's JS storage,
/// out of reach from here — so the row shows filename + size + last-
/// modified timestamp and leaves the decision to the user.
class VoiceRecordingsScreen extends StatefulWidget {
  const VoiceRecordingsScreen({super.key});

  @override
  State<VoiceRecordingsScreen> createState() => _VoiceRecordingsScreenState();
}

class _VoiceRecordingRow {
  final File file;
  final String name;
  final int sizeBytes;
  final DateTime modified;
  const _VoiceRecordingRow({
    required this.file,
    required this.name,
    required this.sizeBytes,
    required this.modified,
  });
}

class _VoiceRecordingsScreenState extends State<VoiceRecordingsScreen> {
  bool _loading = true;
  bool _busy = false;
  List<_VoiceRecordingRow> _rows = const [];

  final AudioPlayer _player = AudioPlayer();
  String? _playingPath;
  Duration _playingPosition = Duration.zero;
  Duration _playingDuration = Duration.zero;
  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playingPath = null;
        _playingPosition = Duration.zero;
      });
    });
    _positionSub = _player.onPositionChanged.listen((pos) {
      if (!mounted) return;
      setState(() => _playingPosition = pos);
    });
    _durationSub = _player.onDurationChanged.listen((dur) {
      if (!mounted) return;
      setState(() => _playingDuration = dur);
    });
    _reload();
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(_VoiceRecordingRow row) async {
    final path = row.file.path;
    // Same row tapped again → stop.
    if (_playingPath == path) {
      await _player.stop();
      if (!mounted) return;
      setState(() {
        _playingPath = null;
        _playingPosition = Duration.zero;
      });
      return;
    }
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(path));
      if (!mounted) return;
      setState(() {
        _playingPath = path;
        _playingPosition = Duration.zero;
        _playingDuration = Duration.zero;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playback failed: $e')),
      );
    }
  }

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/manual_audio');
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final rows = <_VoiceRecordingRow>[];
    try {
      final dir = await _dir();
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          if (entry is! File) continue;
          try {
            final stat = await entry.stat();
            rows.add(_VoiceRecordingRow(
              file: entry,
              name: entry.uri.pathSegments.last,
              sizeBytes: stat.size,
              modified: stat.modified,
            ));
          } catch (_) {}
        }
      }
    } catch (_) {}
    // Newest first — matches how the user last used the recorder.
    rows.sort((a, b) => b.modified.compareTo(a.modified));
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _deleteOne(_VoiceRecordingRow row) async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(
          '"${row.name}" (${formatBytes(row.sizeBytes)}). If a manual card '
          'still references this clip it will fail to play afterwards.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      if (_playingPath == row.file.path) {
        await _player.stop();
        _playingPath = null;
      }
      await row.file.delete();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<void> _deleteAll() async {
    if (_busy || _rows.isEmpty) return;
    final totalBytes = _rows.fold<int>(0, (n, r) => n + r.sizeBytes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete every recording?'),
        content: Text(
          'Remove all ${_rows.length} clip(s) (${formatBytes(totalBytes)}). '
          'Manual cards that reference any of these will lose their audio.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    if (_playingPath != null) {
      await _player.stop();
      _playingPath = null;
    }
    var removed = 0;
    var failed = 0;
    for (final r in _rows) {
      try {
        await r.file.delete();
        removed++;
      } catch (_) {
        failed++;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          failed == 0
              ? 'Removed $removed recording(s)'
              : 'Removed $removed — $failed failed',
        )),
      );
      setState(() => _busy = false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Delete all',
            onPressed: (_busy || _rows.isEmpty) ? null : _deleteAll,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? Center(
                  child: Text(
                    'No voice recordings on this device.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                  ),
                )
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 0),
                  itemBuilder: (ctx, i) {
                    final r = _rows[i];
                    final isPlaying = _playingPath == r.file.path;
                    final total = _playingDuration.inMilliseconds;
                    final progress = (isPlaying && total > 0)
                        ? (_playingPosition.inMilliseconds / total).clamp(0.0, 1.0)
                        : null;
                    return ListTile(
                      leading: IconButton(
                        icon: Icon(isPlaying
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline),
                        color: isPlaying ? theme.colorScheme.primary : null,
                        tooltip: isPlaying ? 'Stop' : 'Play',
                        onPressed: _busy ? null : () => _togglePlay(r),
                      ),
                      title: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${formatBytes(r.sizeBytes)} · ${_formatTimestamp(r.modified)}',
                          ),
                          if (isPlaying) ...[
                            const SizedBox(height: 4),
                            LinearProgressIndicator(value: progress),
                            const SizedBox(height: 2),
                            Text(
                              total > 0
                                  ? '${_formatDuration(_playingPosition)} / ${_formatDuration(_playingDuration)}'
                                  : _formatDuration(_playingPosition),
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.hintColor),
                            ),
                          ],
                        ],
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                        tooltip: 'Delete',
                        onPressed: _busy ? null : () => _deleteOne(r),
                      ),
                    );
                  },
                ),
    );
  }

  static String _formatTimestamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = dt.toLocal();
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${two(m)}:${two(s)}';
  }
}
