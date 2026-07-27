import 'package:flutter/material.dart';

import 'db.dart';
import 'tag_capture.dart' show kTagPalette;

/// Sheet result: the set of tag IDs the user wants to filter by. Empty
/// set means "no filter — show everything" (caller may also treat null
/// the same way for a Cancel).
Future<Set<int>?> showTagFilterSheet({
  required BuildContext context,
  required Set<int> initial,
  required int profileId,
}) {
  return showModalBottomSheet<Set<int>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _TagFilterSheet(initial: initial, profileId: profileId),
  );
}

Color _hexColor(String hex) {
  final s = hex.replaceFirst('#', '');
  return Color(int.parse('FF$s', radix: 16));
}

class _TagFilterSheet extends StatefulWidget {
  final Set<int> initial;
  final int profileId;
  const _TagFilterSheet({required this.initial, required this.profileId});

  @override
  State<_TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<_TagFilterSheet> {
  final Set<int> _selected = {};
  List<TagRow> _tags = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial);
    _load();
  }

  Future<void> _load() async {
    final t = await CupitorDb.instance.listTags(widget.profileId);
    if (!mounted) return;
    setState(() {
      _tags = t;
      _loading = false;
    });
  }

  Future<void> _showTagActions(TagRow t) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Container(
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      color: _hexColor(t.color),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Theme.of(ctx).dividerColor),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.name,
                      style: Theme.of(ctx).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit name & color'),
              onTap: () => Navigator.of(ctx).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              iconColor: Theme.of(ctx).colorScheme.error,
              title: Text('Delete tag', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.of(ctx).pop('delete'),
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
    if (!mounted || action == null) return;
    if (action == 'delete') {
      await _confirmDelete(t);
    } else if (action == 'edit') {
      final updated = await _showEditDialog(t);
      if (updated == null) return;
      final changed = updated.name != t.name || updated.color != t.color;
      if (!changed) return;
      await CupitorDb.instance.updateTag(
        t.id,
        name: updated.name != t.name ? updated.name : null,
        color: updated.color != t.color ? updated.color : null,
      );
      if (!mounted) return;
      setState(() {
        _tags = _tags.map((x) => x.id == t.id ? updated : x).toList();
      });
    }
  }

  Future<TagRow?> _showEditDialog(TagRow t) async {
    final nameCtrl = TextEditingController(text: t.name);
    var color = t.color;
    return await showDialog<TagRow>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: const Text('Edit tag'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: 16),
                  const Text('Color'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: kTagPalette.map((hex) {
                      final selected = hex.toUpperCase() == color.toUpperCase();
                      return GestureDetector(
                        onTap: () => setLocal(() => color = hex),
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: _hexColor(hex),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: selected
                                  ? Theme.of(ctx).colorScheme.onSurface
                                  : Theme.of(ctx).dividerColor,
                              width: selected ? 3 : 1,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final n = nameCtrl.text.trim();
                  if (n.isEmpty) return;
                  Navigator.of(ctx).pop(TagRow(id: t.id, profileId: t.profileId, name: n, color: color));
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(TagRow t) async {
    final n = await CupitorDb.instance.countSentencesForTag(t.id);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete tag "${t.name}"?'),
        content: Text(
          n == 0
              ? 'No sentences are tagged with this tag.'
              : '$n sentence${n == 1 ? '' : 's'} ${n == 1 ? 'is' : 'are'} tagged with "${t.name}". '
                  'The tag will be removed from them but the sentences will stay.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await CupitorDb.instance.deleteTag(t.id);
    if (!mounted) return;
    setState(() {
      _tags = _tags.where((x) => x.id != t.id).toList();
      _selected.remove(t.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36, height: 4, margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Filter by tag', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Sentences without any selected tag will be faded. Tap × to delete a tag, or long-press for rename / recolor.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_tags.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No tags yet. Capture a sentence first.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _tags.map((t) {
                  final sel = _selected.contains(t.id);
                  return GestureDetector(
                    onLongPress: () => _showTagActions(t),
                    child: FilterChip(
                      label: Text(t.name),
                      selected: sel,
                      showCheckmark: false,
                      backgroundColor: _hexColor(t.color).withValues(alpha: 0.15),
                      selectedColor: _hexColor(t.color).withValues(alpha: 0.45),
                      side: BorderSide(color: _hexColor(t.color)),
                      onSelected: (v) => setState(() {
                        if (v) {
                          _selected.add(t.id);
                        } else {
                          _selected.remove(t.id);
                        }
                      }),
                      onDeleted: () => _confirmDelete(t),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      deleteButtonTooltipMessage: 'Delete tag',
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, <int>{}),
                  child: const Text('Clear filter'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
