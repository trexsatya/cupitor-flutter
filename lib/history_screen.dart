/// The full browsing-history list.
///
/// The URL bar's drop-down is the fast path — a few best guesses while you
/// type. This is the slow path: everything, searchable, removable. Tapping a
/// row pops with its address so the caller can load it.
library;

import 'package:flutter/material.dart';

import 'history_store.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'Every remembered page is forgotten. The URL bar stops suggesting '
          'them. Nothing else is affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await HistoryStore.clear();
  }

  String _when(int ms) {
    if (ms <= 0) return '';
    final then = DateTime.fromMillisecondsSinceEpoch(ms);
    final d = DateTime.now().difference(then);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return '${then.year}-${then.month.toString().padLeft(2, '0')}-'
        '${then.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _confirmClear,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search history',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(_search.clear),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
      ),
      body: ValueListenableBuilder<List<HistoryEntry>>(
        valueListenable: HistoryStore.entries,
        builder: (context, all, _) {
          // No limit here: this screen is the place you come to when the
          // drop-down's few guesses were not the one you wanted.
          final shown = rankHistorySuggestions(all, _search.text, limit: all.length);
          if (shown.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  all.isEmpty
                      ? 'Nothing here yet. Pages you visit are remembered so '
                          'the URL bar can suggest them.'
                      : 'No page matches "${_search.text.trim()}".',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: shown.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = shown[i];
              return Dismissible(
                key: ValueKey(e.url),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: theme.colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: Icon(Icons.delete_outline,
                      color: theme.colorScheme.onErrorContainer),
                ),
                onDismissed: (_) => HistoryStore.remove(e.url),
                child: ListTile(
                  title: Text(e.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    e.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_when(e.lastVisited), style: theme.textTheme.bodySmall),
                      if (e.visitCount > 1)
                        Text('${e.visitCount}×',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                    ],
                  ),
                  onTap: () => Navigator.of(context).pop(e.url),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
