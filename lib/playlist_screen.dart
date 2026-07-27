import 'package:flutter/material.dart';

import 'db.dart';
import 'playlist_service.dart';

/// Full-screen playlist manager.
///
/// Lists every user-created playlist across the top (chip row), plus
/// the active playlist's items below with reorder / delete. New
/// playlists are created via the app-bar `+`; renaming happens via
/// long-press on a chip.
///
/// The screen is intentionally self-contained — it doesn't know about
/// the EPUB reader or the language WebView. Mutations flow through
/// [PlaylistService] which the reader's capture chip and dialog1's
/// push logic subscribe to.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<PlaylistRow> _playlists = const [];
  List<PlaylistItemRow> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    PlaylistService.changes.addListener(_onChanges);
    PlaylistService.activeId.addListener(_onChanges);
    _load();
  }

  @override
  void dispose() {
    PlaylistService.changes.removeListener(_onChanges);
    PlaylistService.activeId.removeListener(_onChanges);
    super.dispose();
  }

  void _onChanges() { _load(); }

  Future<void> _load() async {
    final playlists = await CupitorDb.instance.listPlaylists();
    List<PlaylistItemRow> items = const [];
    final active = PlaylistService.activeId.value;
    if (active != null) {
      items = await CupitorDb.instance.listPlaylistItems(active);
    }
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _items = items;
      _loading = false;
    });
  }

  Future<void> _createPlaylist() async {
    final name = await _promptForName(title: 'New playlist', initial: '');
    if (name == null || name.trim().isEmpty) return;
    await PlaylistService.createPlaylist(name.trim());
  }

  Future<String?> _promptForName({required String title, required String initial}) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _renamePlaylist(PlaylistRow p) async {
    final name = await _promptForName(title: 'Rename playlist', initial: p.name);
    if (name == null || name.trim().isEmpty || name.trim() == p.name) return;
    await PlaylistService.renamePlaylist(p.id, name.trim());
  }

  Future<void> _confirmDeletePlaylist(PlaylistRow p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('"${p.name}" and all its captured sentences will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await PlaylistService.deletePlaylist(p.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New playlist',
            onPressed: _createPlaylist,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildChipRow(theme),
                const Divider(height: 1),
                if (_playlists.isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No playlists yet. Tap + to create one, then arm the '
                          '"Add to playlist" chip in the EPUB reader to start '
                          'collecting sentences.',
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(child: _buildItems(theme)),
              ],
            ),
    );
  }

  Widget _buildChipRow(ThemeData theme) {
    final active = PlaylistService.activeId.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final p in _playlists)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onLongPress: () => _showChipMenu(p),
                  child: ChoiceChip(
                    label: Text(p.name),
                    selected: p.id == active,
                    onSelected: (_) => PlaylistService.setActive(p.id),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showChipMenu(PlaylistRow p) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text('Rename "${p.name}"'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') await _renamePlaylist(p);
    if (action == 'delete') await _confirmDeletePlaylist(p);
  }

  Widget _buildItems(ThemeData theme) {
    final active = PlaylistService.activeId.value;
    if (active == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Tap a playlist above to view its cards.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No cards in this playlist yet. Arm the "Add to playlist" chip in '
            'the EPUB reader and tap sentences to add them.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      itemCount: _items.length,
      onReorder: (oldIdx, newIdx) async {
        if (newIdx > oldIdx) newIdx -= 1;
        final ids = _items.map((i) => i.id).toList();
        final moved = ids.removeAt(oldIdx);
        ids.insert(newIdx, moved);
        await PlaylistService.reorderItems(active, ids);
      },
      itemBuilder: (_, i) {
        final item = _items[i];
        return Dismissible(
          key: ValueKey('item-${item.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: theme.colorScheme.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: Icon(Icons.delete, color: theme.colorScheme.onError),
          ),
          onDismissed: (_) => PlaylistService.deleteItem(item.id),
          child: ListTile(
            leading: const Icon(Icons.drag_indicator),
            title: Text(
              item.sentenceText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if ((item.bookTitle ?? '').isNotEmpty) item.bookTitle!,
                if ((item.chapterTitle ?? '').isNotEmpty) item.chapterTitle!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              color: theme.colorScheme.error,
              onPressed: () => PlaylistService.deleteItem(item.id),
            ),
          ),
        );
      },
    );
  }
}
