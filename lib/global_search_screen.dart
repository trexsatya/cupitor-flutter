import 'dart:async';

import 'package:flutter/material.dart';

import 'global_search.dart';
import 'search_index.dart';

/// Search across every EPUB in the library. Query grammar mirrors the
/// module: pipe-separated OR-phrases, spaces literal, case-insensitive
/// substring. Results stream in as chapters are scanned so the user
/// sees hits from small books before large ones finish parsing.
class GlobalSearchScreen extends StatefulWidget {
  final String? initialQuery;

  /// Called when the user taps a hit. The host wires this into
  /// whatever the correct "open book at chapter" flow is
  /// (`_openEpubByKey` in main.dart, typically). The third argument
  /// is the current query string so the host can pass it through as
  /// a highlight — the reader will open with the find bar prefilled
  /// and the first match scrolled into view.
  final Future<void> Function(String bookKey, int chapterIdx, String? highlight) onOpen;

  const GlobalSearchScreen({
    super.key,
    this.initialQuery,
    required this.onOpen,
  });

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  late final TextEditingController _query =
      TextEditingController(text: widget.initialQuery ?? '');
  final FocusNode _focus = FocusNode();

  StreamSubscription<GlobalSearchEvent>? _sub;
  List<GlobalSearchHit> _hits = const [];
  GlobalSearchProgress? _progress;
  bool _running = false;
  bool _done = false;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if ((widget.initialQuery ?? '').trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _run);
  }

  Future<void> _run() async {
    await _sub?.cancel();
    setState(() {
      _hits = const [];
      _progress = null;
      _running = true;
      _done = false;
    });
    _sub = GlobalSearch.search(_query.text).listen((ev) {
      if (!mounted) return;
      if (ev is GlobalSearchHitEvent) {
        setState(() => _hits = [..._hits, ev.hit]);
      } else if (ev is GlobalSearchProgressEvent) {
        setState(() => _progress = ev.progress);
      } else if (ev is GlobalSearchDone) {
        setState(() {
          _running = false;
          _done = true;
        });
      }
    }, onDone: () {
      if (!mounted) return;
      setState(() => _running = false);
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _running = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Global search'),
        actions: [
          IconButton(
            icon: const Icon(Icons.storage),
            tooltip: 'Search index',
            onPressed: () => _showIndexSheet(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              focusNode: _focus,
              autofocus: widget.initialQuery == null,
              decoration: InputDecoration(
                labelText: 'Query',
                hintText: 'e.g. cat|dog · "apple pie|orange juice"',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _query.clear();
                          _onChanged('');
                          setState(() {});
                        },
                      ),
              ),
              onChanged: (v) {
                _onChanged(v);
                setState(() {}); // refresh suffix visibility
              },
              onSubmitted: (_) => _run(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _statusLine(),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                ),
                if (_running)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _hits.isEmpty
                ? _emptyState(theme)
                : ListView.separated(
                    itemCount: _hits.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _hitTile(theme, _hits[i]),
                  ),
          ),
        ],
      ),
    );
  }

  void _showIndexSheet(BuildContext outerCtx) {
    showModalBottomSheet<void>(
      context: outerCtx,
      isScrollControlled: true,
      builder: (_) => const _IndexSettingsSheet(),
    );
  }

  String _statusLine() {
    final p = _progress;
    if (p == null) {
      if (_query.text.trim().isEmpty) return 'Enter a query to begin.';
      return _running ? 'Scanning…' : (_done ? 'No matches.' : '');
    }
    return '${p.hitsSoFar} hit(s) · scanned ${p.booksScanned}/${p.booksTotal} book(s)';
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _running || _query.text.trim().isEmpty
              ? _running
                  ? 'Scanning your library…'
                  : 'Type a phrase to search all EPUB and DOCX books. Use `|` for OR:\n'
                      '  cat|dog\n  apple pie|orange juice'
              : 'No matches in the library.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
        ),
      ),
    );
  }

  Widget _hitTile(ThemeData theme, GlobalSearchHit h) {
    return InkWell(
      onTap: () {
        final q = _query.text.trim();
        widget.onOpen(h.bookKey, h.chapterIdx, q.isEmpty ? null : q);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              h.bookTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              h.chapterTitle.isEmpty ? 'Chapter ${h.chapterIdx + 1}' : h.chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 6),
            for (final s in h.snippets)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text.rich(
                  TextSpan(children: [
                    if (s.before.isNotEmpty) TextSpan(text: '…${s.before}'),
                    TextSpan(
                      text: s.match,
                      style: TextStyle(
                        backgroundColor:
                            theme.colorScheme.primary.withValues(alpha: 0.25),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (s.after.isNotEmpty) TextSpan(text: '${s.after}…'),
                  ]),
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Sheet exposing the search index: current used bytes vs capacity,
/// preset radio buttons for the byte cap (including 0 = disabled),
/// and a Clear button that flushes the index without changing the
/// cap. Listens to `SearchIndex.statsRevision` so the stats line
/// updates live as searches populate the index.
class _IndexSettingsSheet extends StatefulWidget {
  const _IndexSettingsSheet();

  @override
  State<_IndexSettingsSheet> createState() => _IndexSettingsSheetState();
}

class _IndexSettingsSheetState extends State<_IndexSettingsSheet> {
  ({int usedBytes, int bookCount, int capacityBytes, bool available})? _stats;

  @override
  void initState() {
    super.initState();
    _refresh();
    SearchIndex.statsRevision.addListener(_refresh);
  }

  @override
  void dispose() {
    SearchIndex.statsRevision.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await SearchIndex.stats();
    if (!mounted) return;
    setState(() => _stats = s);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _stats;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storage, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Search index',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'On-disk full-text index (SQLite FTS5). Books get indexed '
              'the first time a search touches them; subsequent searches '
              'hit the index directly. The cap is a soft ceiling — '
              'least-recently-used books evict when the index reaches it. '
              'Single-word queries under ${GlobalSearchQuery.minTokenChars} chars are dropped.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            if (s == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            else ...[
              Text(
                s.capacityBytes == 0
                    ? 'Index disabled · every search re-parses each book'
                    : !s.available
                        ? 'Index unavailable on this device — using linear fallback'
                        : '${_formatBytes(s.usedBytes)} used · '
                            '${_formatBytes(s.capacityBytes)} cap · '
                            '${s.bookCount} book(s)',
                style: theme.textTheme.bodyMedium,
              ),
              if (s.capacityBytes > 0 && s.available) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (s.usedBytes / s.capacityBytes).clamp(0.0, 1.0),
                    minHeight: 6,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: SearchIndex.partialMatchEnabled,
              builder: (_, on, __) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: on,
                onChanged: (v) => SearchIndex.partialMatchEnabled.value = v,
                title: const Text('Partial (substring) matching'),
                subtitle: Text(
                  on
                      ? '`x` matches box, matrix, xylophone. `x y` → both x and y appear anywhere. Slower — bypasses the FTS5 tokenizer.'
                      : 'Off: `x` matches x, xylophone (prefix). Exact whole-word hits are prioritised in snippets.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Capacity',
                style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            ValueListenableBuilder<int>(
              valueListenable: SearchIndex.capacityBytes,
              builder: (_, current, __) => Column(
                children: [
                  for (final preset in SearchIndex.capacityPresets)
                    RadioListTile<int>(
                      dense: true,
                      value: preset,
                      groupValue: current,
                      title: Text(preset == 0
                          ? 'Disabled — 0 B'
                          : _formatBytes(preset)),
                      onChanged: (v) {
                        if (v != null) SearchIndex.setCapacity(v);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear index'),
                  onPressed: () async {
                    await SearchIndex.clear();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int n) {
  const units = ['B', 'KB', 'MB', 'GB'];
  double v = n.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++; }
  final s = v >= 100
      ? v.toStringAsFixed(0)
      : v >= 10
          ? v.toStringAsFixed(1)
          : v.toStringAsFixed(2);
  return '$s ${units[u]}';
}
