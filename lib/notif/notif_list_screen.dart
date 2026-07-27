import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notif_dao.dart';
import 'notif_ops.dart';
import 'notif_settings.dart';
import 'notif_ui_util.dart';

/// List detail + authoring (spec §In-app UI): items with step and next-due,
/// add/edit/remove, reset-to-step-1, pause/resume, change schedule, rename,
/// delete list. This is also where app-authored lists get their items, so
/// the feature works without the webpage.
class NotifListScreen extends StatefulWidget {
  final int listId;
  final Future<NotifDao?> Function() dao;
  final Future<void> Function() rearm;
  const NotifListScreen(
      {super.key,
      required this.listId,
      required this.dao,
      required this.rearm});

  @override
  State<NotifListScreen> createState() => _NotifListScreenState();
}

class _NotifListScreenState extends State<NotifListScreen> {
  NotifListRow? _list;
  NotifScheduleRow? _schedule;
  NotifScheduleRow? _introSchedule;
  List<NotifItemRow> _items = const [];
  bool _loading = true;
  bool _unsupported = false;

  tz.TZDateTime get _now => tz.TZDateTime.now(tz.local);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await widget.dao();
    if (d == null) {
      // Self-disable posture: show the notice, never a dead spinner.
      if (mounted) setState(() { _unsupported = true; _loading = false; });
      return;
    }
    final list = await d.listById(widget.listId);
    if (list == null) {
      // Deleted underneath us (e.g. by the webpage) — nothing to show.
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final schedule =
        list.scheduleId == null ? null : await d.scheduleById(list.scheduleId!);
    final introSchedule = list.introScheduleId == null
        ? null
        : await d.scheduleById(list.introScheduleId!);
    final items = await d.itemsForList(list.id);
    if (!mounted) return;
    setState(() {
      _list = list;
      _schedule = schedule;
      _introSchedule = introSchedule;
      _items = items;
      _loading = false;
    });
  }

  Future<void> _mutate(Future<void> Function(NotifDao d) fn) async {
    final d = await widget.dao();
    if (d == null) return;
    try {
      await fn(d);
    } catch (_) {
      // Never-crash posture: a storage failure surfaces, nothing throws
      // into the framework.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save the change.')));
      }
      return;
    }
    await widget.rearm();
    await _load();
  }

  // ── list-level actions ──────────────────────────────────────────────

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _list!.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename list'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Name', border: OutlineInputBorder(), isDense: true),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('OK')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _mutate((d) => d.updateList(_list!.id, {'name': name.trim()}));
  }

  Future<void> _changeSchedule() async {
    final d = await widget.dao();
    if (d == null) return;
    final schedules = await d.listSchedules();
    if (!mounted) return;
    final picked = await showDialog<NotifScheduleRow>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Schedule'),
        children: [
          for (final s in schedules)
            RadioListTile<int>(
              value: s.id,
              groupValue: _list!.scheduleId,
              title: Text(s.name),
              subtitle:
                  Text(s.kind == 'series' ? 'Spaced series' : 'Recurring'),
              onChanged: (_) => Navigator.pop(ctx, s),
            ),
        ],
      ),
    );
    if (picked == null) return;
    NotifScheduleRow? intro;
    if (picked.kind == 'series') {
      final recurring = schedules
          .where((s) => s.kind == 'recurring')
          .toList(growable: false);
      if (!mounted) return;
      // Sentinel-wrapped picker: null result = dialog dismissed (abort),
      // (null,) = "All at once", (row,) = that intro cadence.
      final introChoice = await showDialog<(NotifScheduleRow?,)>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Introduce items'),
          children: [
            RadioListTile<int?>(
              value: null,
              groupValue: _list!.introScheduleId,
              title: const Text('All at once'),
              onChanged: (_) => Navigator.pop(ctx, (null,)),
            ),
            for (final s in recurring)
              RadioListTile<int?>(
                value: s.id,
                groupValue: _list!.introScheduleId,
                title: Text(s.name),
                onChanged: (_) => Navigator.pop(ctx, (s,)),
              ),
          ],
        ),
      );
      if (introChoice == null) return;
      intro = introChoice.$1;
    }
    await _mutate((d) => applyScheduleToList(
        d, _list!, picked, _now, NotifSettings.window, intro: intro));
  }

  /// List-level notification deep link (v9): items without their own
  /// open_url inherit it on tap. Empty input clears it.
  Future<void> _editOpenUrl() async {
    final ctrl = TextEditingController(text: _list!.openUrl ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open link'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'URL opened on notification tap',
            helperText: 'Applies to every item without its own link. '
                'Leave empty to just show the study page.',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('OK')),
        ],
      ),
    );
    if (result == null) return;
    final v = result.trim();
    await _mutate(
        (d) => d.updateList(_list!.id, {'open_url': v.isEmpty ? null : v}));
  }

  Future<void> _togglePaused() async {
    final next = _list!.status == 'paused' ? 'active' : 'paused';
    await _mutate(
        (d) => setListStatus(d, _list!, next, _now, NotifSettings.window));
  }

  Future<void> _deleteList() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete list?'),
        content: Text(
            '"${_list!.name}", its ${_items.length} items, and their review '
            'history will be removed. Pending notifications are cancelled.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final d = await widget.dao();
    if (d == null) return;
    await d.deleteList(_list!.id);
    await widget.rearm();
    if (mounted) Navigator.of(context).pop();
  }

  // ── item-level actions ──────────────────────────────────────────────

  /// Shared add/edit dialog. Returns (title, body, openUrl) or null.
  Future<(String, String?, String?)?> _itemDialog(
      {NotifItemRow? existing}) async {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final bodyCtrl = TextEditingController(text: existing?.body ?? '');
    final urlCtrl = TextEditingController(text: existing?.openUrl ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New item' : 'Edit item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bodyCtrl,
              decoration: const InputDecoration(
                  labelText: 'Body (optional)',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                  labelText: 'Open URL (optional)',
                  border: OutlineInputBorder(),
                  isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('OK')),
        ],
      ),
    );
    final title = titleCtrl.text.trim();
    if (ok != true || title.isEmpty) return null;
    String? orNull(String s) => s.trim().isEmpty ? null : s.trim();
    return (title, orNull(bodyCtrl.text), orNull(urlCtrl.text));
  }

  Future<void> _addItem() async {
    final r = await _itemDialog();
    if (r == null) return;
    final (title, body, openUrl) = r;
    final hasIntro = _list!.introScheduleId != null;
    await _mutate((d) async {
      await d.insertItem(
        listId: _list!.id,
        title: title,
        body: body,
        openUrl: openUrl,
        position: _items.length,
        // Intro lists queue new items unseeded; the cadence fires them.
        nextDueAt: hasIntro
            ? null
            : initialNextDueMs(_schedule, _now, NotifSettings.window),
      );
      if (hasIntro) {
        await ensureIntroArmed(d, _list!, _now, NotifSettings.window);
      }
    });
  }

  Future<void> _editItem(NotifItemRow item) async {
    final r = await _itemDialog(existing: item);
    if (r == null) return;
    final (title, body, openUrl) = r;
    await _mutate((d) => d.updateItem(item.id,
        {'title': title, 'body': body, 'open_url': openUrl}));
  }

  Future<void> _resetItem(NotifItemRow item) async {
    final hasIntro = _list!.introScheduleId != null;
    await _mutate((d) async {
      if (hasIntro) {
        // In an intro list "the start" is the back of the intro queue.
        await d.updateItem(item.id, {
          'step': 0,
          'status': 'active',
          'next_due_at': null,
          'last_grade': null,
        });
        await ensureIntroArmed(d, _list!, _now, NotifSettings.window);
      } else {
        await resetItemToStart(d, item, _schedule, _now, NotifSettings.window);
      }
    });
  }

  Future<void> _deleteItem(NotifItemRow item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('"${item.title}" and its review history will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _mutate((d) => d.deleteItem(item.id));
  }

  // ── build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_unsupported) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child:
                Text('Notifications are not available on this platform.'),
          ),
        ),
      );
    }
    if (_loading || _list == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final paused = _list!.status == 'paused';
    return Scaffold(
      appBar: AppBar(
        title: Text(_list!.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'rename' => _rename(),
              'schedule' => _changeSchedule(),
              'openUrl' => _editOpenUrl(),
              'pause' => _togglePaused(),
              'delete' => _deleteList(),
              _ => Future<void>.value(),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(
                  value: 'schedule', child: Text('Change schedule')),
              const PopupMenuItem(
                  value: 'openUrl', child: Text('Set open link')),
              PopupMenuItem(
                  value: 'pause', child: Text(paused ? 'Resume' : 'Pause')),
              const PopupMenuItem(value: 'delete', child: Text('Delete list')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add item',
        onPressed: _addItem,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Chip(
                  avatar: Icon(
                      _schedule?.kind == 'recurring'
                          ? Icons.repeat
                          : Icons.stairs_outlined,
                      size: 18),
                  label: Text(_schedule?.name ?? 'No schedule'),
                ),
                const SizedBox(width: 8),
                if (_introSchedule != null) ...[
                  Chip(
                    avatar: const Icon(Icons.start, size: 18),
                    label: Text('intro: ${_introSchedule!.name}'),
                  ),
                  const SizedBox(width: 8),
                ],
                if (paused)
                  Chip(
                    label: const Text('paused'),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No items yet. Tap + to add one.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.hintColor),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (_, i) => _itemTile(theme, _items[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(ThemeData theme, NotifItemRow item) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isSeries = _schedule?.kind == 'series';
    final state = switch (item.status) {
      'done' => 'done',
      'suspended' => 'suspended',
      _ when isSeries &&
              item.nextDueAt == null &&
              _list!.introScheduleId != null =>
        'queued for introduction',
      _ => isSeries
          ? 'step ${item.step + 1} · ${formatDue(item.nextDueAt, nowMs)}'
          : 'in rotation',
    };
    return ListTile(
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if ((item.body ?? '').isNotEmpty) item.body!, state].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => switch (v) {
          'edit' => _editItem(item),
          'reset' => _resetItem(item),
          'delete' => _deleteItem(item),
          _ => Future<void>.value(),
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          const PopupMenuItem(
              value: 'reset', child: Text('Reset to start')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
