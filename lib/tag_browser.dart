import 'package:flutter/material.dart';

import 'db.dart';
import 'media_manager.dart';
import 'profile_service.dart';

Color _hexColor(String hex) {
  final s = hex.replaceFirst('#', '');
  return Color(int.parse('FF$s', radix: 16));
}

/// Global browser for tagged sentences. Defaults to the current page
/// (passed in via [currentSurface] + [currentLocator]) and exposes a
/// toggle to show every other page too. Tag chips multi-select to
/// filter further within the current scope.
///
/// Tapping a row from a DIFFERENT page asks the caller to navigate
/// there via [onNavigate]; tapping a row on the current page just
/// pops back so the user can scroll to it. Long-press opens the
/// edit sheet via [onEdit].
class TagBrowserScreen extends StatefulWidget {
  final String? currentSurface;
  final String? currentLocator;
  final void Function(String url) onNavigate;
  final Future<void> Function(int dbid) onEdit;
  const TagBrowserScreen({
    super.key,
    required this.currentSurface,
    required this.currentLocator,
    required this.onNavigate,
    required this.onEdit,
  });

  @override
  State<TagBrowserScreen> createState() => _TagBrowserScreenState();
}

class _TagBrowserScreenState extends State<TagBrowserScreen> {
  List<TaggedSentenceRow> _all = const [];
  List<TagRow> _tags = const [];
  bool _loading = true;
  // Default to "current page only" per the user request — show what's
  // tagged on the page they came from first, with a one-tap escape
  // hatch to expand to everything.
  bool _currentPageOnly = true;
  // 'all' | 'web' | 'epub' — surface filter applied to "All pages".
  String _surfaceFilter = 'all';
  final Set<int> _tagFilter = {};
  final TextEditingController _searchCtrl = TextEditingController();
  // Track which page-group headers are collapsed.
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final profileId = ProfileService.currentId;
    final rows = await CupitorDb.instance.allTaggedSentences(profileId);
    final tags = await CupitorDb.instance.listTags(profileId);
    if (!mounted) return;
    setState(() {
      _all = rows;
      _tags = tags;
      _loading = false;
    });
  }

  Future<void> _openMediaManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaManagerScreen(
          profileId: ProfileService.currentId,
          // A media row's navigation only matters for web pages here —
          // EPUB locators need reader context we don't own. When it's a
          // web row, close this screen and forward the URL up through
          // the tag-browser's [onNavigate] just like a sentence tap.
          onNavigateToSentence: (surface, locator) {
            if (surface != 'web') return;
            Navigator.of(context).pop();
            widget.onNavigate(locator);
          },
        ),
      ),
    );
    // Media changes may have deleted sentences via last-ref cascades
    // elsewhere — reload so counts stay honest.
    if (mounted) _load();
  }

  Iterable<TaggedSentenceRow> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _all.where((r) {
      if (_currentPageOnly) {
        if (widget.currentSurface == null || widget.currentLocator == null) {
          return false;
        }
        if (r.surface != widget.currentSurface) return false;
        if (r.locator != widget.currentLocator) return false;
      } else if (_surfaceFilter == 'web' && r.surface != 'web') {
        return false;
      } else if (_surfaceFilter == 'epub' && r.surface != 'epub') {
        return false;
      }
      if (_tagFilter.isNotEmpty) {
        final hit = r.sentence.tags.any((t) => _tagFilter.contains(t.id));
        if (!hit) return false;
      }
      if (q.isNotEmpty) {
        // Whitespace-insensitive: a sentence may carry the line breaks the
        // reader saw, and a two-word query must still find it across one.
        final inText = sentenceTextKey(r.sentence.text).toLowerCase().contains(q);
        final inMask = (r.sentence.mask ?? '').toLowerCase().contains(q);
        final inTitle = (r.pageTitle ?? '').toLowerCase().contains(q);
        if (!inText && !inMask && !inTitle) return false;
      }
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tagged sentences'),
        actions: [
          IconButton(
            icon: const Icon(Icons.perm_media_outlined),
            tooltip: 'Media manager',
            onPressed: _openMediaManager,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () { setState(() => _loading = true); _load(); },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                ValueListenableBuilder<ProfileRow?>(
                  valueListenable: ProfileService.active,
                  builder: (_, p, __) => Container(
                    width: double.infinity,
                    color: theme.colorScheme.surfaceContainerLow,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    child: Text(
                      'Profile: ${p?.name ?? "Default"}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                  ),
                ),
                _buildFilterBar(theme),
                if (filtered.isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _currentPageOnly
                              ? 'No tagged sentences on the current page.\nTap "All pages" to broaden the search.'
                              : 'No tagged sentences match your filters.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(child: _buildList(filtered, theme)),
              ],
            ),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ChoiceChip(
                  label: const Text('Current page'),
                  selected: _currentPageOnly,
                  onSelected: (_) => setState(() => _currentPageOnly = true),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('All pages'),
                  selected: !_currentPageOnly,
                  onSelected: (_) => setState(() => _currentPageOnly = false),
                ),
                const Spacer(),
                Text(
                  '${_filtered.length} sentence${_filtered.length == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
            if (!_currentPageOnly) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: _surfaceFilter == 'all',
                    onSelected: (_) => setState(() => _surfaceFilter = 'all'),
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('Web'),
                    selected: _surfaceFilter == 'web',
                    avatar: const Icon(Icons.public, size: 16),
                    onSelected: (_) => setState(() => _surfaceFilter = 'web'),
                  ),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: const Text('EPUB'),
                    selected: _surfaceFilter == 'epub',
                    avatar: const Icon(Icons.menu_book_outlined, size: 16),
                    onSelected: (_) => setState(() => _surfaceFilter = 'epub'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search text, mask, or page title…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            if (_tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: _tags.map((t) {
                    final sel = _tagFilter.contains(t.id);
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(t.name),
                        selected: sel,
                        showCheckmark: false,
                        backgroundColor: _hexColor(t.color).withValues(alpha: 0.15),
                        selectedColor: _hexColor(t.color).withValues(alpha: 0.45),
                        side: BorderSide(color: _hexColor(t.color)),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _tagFilter.add(t.id);
                          } else {
                            _tagFilter.remove(t.id);
                          }
                        }),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<TaggedSentenceRow> rows, ThemeData theme) {
    // Group by page so multiple sentences on the same page show under
    // one page header — easier to scan than a flat list when broad.
    final groups = <String, List<TaggedSentenceRow>>{};
    final order = <String>[];
    for (final r in rows) {
      final key = '${r.surface}${r.locator}';
      if (!groups.containsKey(key)) order.add(key);
      groups.putIfAbsent(key, () => []).add(r);
    }
    return ListView.builder(
      itemCount: order.length,
      itemBuilder: (ctx, i) {
        final key = order[i];
        final group = groups[key]!;
        final first = group.first;
        final collapsed = _collapsed.contains(key);
        return _PageGroup(
          surface: first.surface,
          locator: first.locator,
          title: first.pageTitle,
          rows: group,
          collapsed: collapsed,
          onToggleCollapsed: () => setState(() {
            if (collapsed) {
              _collapsed.remove(key);
            } else {
              _collapsed.add(key);
            }
          }),
          onOpenPage: () {
            Navigator.of(context).pop();
            widget.onNavigate(first.locator);
          },
          onTapRow: (row) {
            if (row.surface != 'web') {
              // EPUB rows aren't navigable from here in v1.
              return;
            }
            Navigator.of(context).pop();
            widget.onNavigate(row.locator);
          },
          onLongPressRow: (row) async {
            await widget.onEdit(row.sentence.id);
            // Refresh so any edit (or delete-via-untag) shows.
            if (mounted) _load();
          },
          onDeleteRow: (row) async {
            final ok = await CupitorDb.instance.deleteSentence(row.sentence.id);
            if (!ok || !mounted) return;
            setState(() {
              _all = _all
                  .where((r) => r.sentence.id != row.sentence.id)
                  .toList(growable: false);
            });
          },
        );
      },
    );
  }
}

class _PageGroup extends StatelessWidget {
  final String surface;
  final String locator;
  final String? title;
  final List<TaggedSentenceRow> rows;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onOpenPage;
  final void Function(TaggedSentenceRow) onTapRow;
  final void Function(TaggedSentenceRow) onLongPressRow;
  final void Function(TaggedSentenceRow) onDeleteRow;
  const _PageGroup({
    required this.surface,
    required this.locator,
    required this.title,
    required this.rows,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onOpenPage,
    required this.onTapRow,
    required this.onLongPressRow,
    required this.onDeleteRow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggleCollapsed,
          child: Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 18,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 2),
                Icon(
                  surface == 'web' ? Icons.public : Icons.menu_book_outlined,
                  size: 16,
                  color: theme.hintColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null && title!.isNotEmpty)
                        Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      Text(
                        locator,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${rows.length}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
                IconButton(
                  icon: const Icon(Icons.launch, size: 18),
                  tooltip: 'Open page',
                  visualDensity: VisualDensity.compact,
                  onPressed: onOpenPage,
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          for (final r in rows)
          Dismissible(
            key: ValueKey('sent-${r.sentence.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              color: theme.colorScheme.error,
              padding: const EdgeInsets.only(right: 16),
              child: Icon(Icons.delete, color: theme.colorScheme.onError),
            ),
            confirmDismiss: (_) async {
              return await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Remove sentence?'),
                  content: const Text('The sentence and its tag associations will be deleted.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                  ],
                ),
              ) ?? false;
            },
            onDismissed: (_) => onDeleteRow(r),
            child: InkWell(
              onTap: () => onTapRow(r),
              onLongPress: () => onLongPressRow(r),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _sentenceTextWithMediaIcons(
                            text: r.sentence.text,
                            kinds: r.mediaKinds,
                            theme: theme,
                          ),
                          if ((r.sentence.mask ?? '').isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              '→ ${r.sentence.mask}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: theme.hintColor,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: r.sentence.tags.map((t) {
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: _hexColor(t.color).withValues(alpha: 0.35),
                                  border: Border.all(color: _hexColor(t.color)),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  t.name,
                                  style: theme.textTheme.bodySmall,
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      tooltip: 'Edit tags / mask',
                      onPressed: () => onLongPressRow(r),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Delete sentence',
                      color: theme.colorScheme.error,
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Remove sentence?'),
                            content: const Text(
                              'The sentence and its tag associations will be deleted.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) onDeleteRow(r);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Sentence body with inline media-kind icons prepended when the row
/// has attachments. Uses [Text.rich] + [WidgetSpan] so icons flow with
/// the text (multi-line + ellipsis stay natural). Icon order is fixed
/// — image, audio, video, link — so a mixed row always reads the
/// same way at a glance.
Widget _sentenceTextWithMediaIcons({
  required String text,
  required Set<String> kinds,
  required ThemeData theme,
}) {
  if (kinds.isEmpty) {
    return Text(
      text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium,
    );
  }
  IconData? iconFor(String kind) {
    switch (kind) {
      case 'image': return Icons.image_outlined;
      case 'audio': return Icons.audiotrack;
      case 'video': return Icons.videocam_outlined;
      case 'link': return Icons.link;
    }
    return null;
  }
  const order = ['image', 'audio', 'video', 'link'];
  final spans = <InlineSpan>[];
  for (final k in order) {
    if (!kinds.contains(k)) continue;
    final ic = iconFor(k);
    if (ic == null) continue;
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Icon(ic, size: 16, color: theme.colorScheme.primary),
      ),
    ));
  }
  spans.add(TextSpan(text: text));
  return Text.rich(
    TextSpan(children: spans),
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    style: theme.textTheme.bodyMedium,
  );
}
