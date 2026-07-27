import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import 'notif_dao.dart';
import 'notif_ops.dart';
import 'notif_settings.dart';
import 'notif_ui_util.dart';
import 'schedules.dart';

/// Schedule index + editor (spec §In-app UI). Built-ins are visible and
/// clonable but not editable; customs are editable, and deletable only when
/// no list uses them. Deps are injected so widget tests run on an in-memory
/// DAO with a counting rearm.
class ScheduleListScreen extends StatefulWidget {
  final Future<NotifDao?> Function() dao;
  final Future<void> Function() rearm;
  const ScheduleListScreen({super.key, required this.dao, required this.rearm});

  @override
  State<ScheduleListScreen> createState() => _ScheduleListScreenState();
}

class _ScheduleListScreenState extends State<ScheduleListScreen> {
  List<NotifScheduleRow> _schedules = const [];
  Map<int, int> _useCounts = const {};
  bool _loading = true;
  bool _unsupported = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await widget.dao();
    if (d == null) {
      if (mounted) setState(() { _unsupported = true; _loading = false; });
      return;
    }
    final schedules = await d.listSchedules();
    final counts = <int, int>{};
    for (final s in schedules) {
      counts[s.id] = (await d.listsUsingSchedule(s.id)).length;
    }
    if (!mounted) return;
    setState(() {
      _schedules = schedules;
      _useCounts = counts;
      _loading = false;
    });
  }

  Future<void> _openEditor({NotifScheduleRow? existing,
      NotifScheduleRow? cloneOf}) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ScheduleEditorScreen(
          dao: widget.dao, rearm: widget.rearm,
          existing: existing, cloneOf: cloneOf),
    ));
    if (changed == true) await _load();
  }

  Future<void> _confirmDelete(NotifScheduleRow s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete schedule?'),
        content: Text('"${s.name}" will be removed.'),
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
    await d.deleteCustomSchedule(s.id);
    await widget.rearm();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Schedules')),
      floatingActionButton: _unsupported
          ? null
          : FloatingActionButton(
              tooltip: 'New custom schedule',
              onPressed: () => _openEditor(),
              child: const Icon(Icons.add),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _unsupported
              ? const Center(
                  child: Text('Notifications are not available on this platform.'))
              : ListView(
                  children: [
                    for (final s in _schedules) _tile(theme, s),
                    const SizedBox(height: 80),
                  ],
                ),
    );
  }

  Widget _tile(ThemeData theme, NotifScheduleRow s) {
    final builtin = s.builtinKey != null;
    final used = _useCounts[s.id] ?? 0;
    final kindLabel = s.kind == 'series' ? 'Spaced series' : 'Recurring';
    return ListTile(
      leading: Icon(s.kind == 'series' ? Icons.stairs_outlined : Icons.repeat),
      title: Text(s.name),
      subtitle: Text([
        kindLabel,
        if (builtin) 'built-in',
        if (used > 0) 'used by $used list${used == 1 ? '' : 's'}',
      ].join(' · ')),
      onTap: builtin
          ? () => _openEditor(cloneOf: s)
          : () => _openEditor(existing: s),
      trailing: builtin
          ? IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'Clone as custom schedule',
              onPressed: () => _openEditor(cloneOf: s),
            )
          : IconButton(
              icon: Icon(Icons.delete_outline,
                  color: used > 0 ? theme.disabledColor : theme.colorScheme.error),
              tooltip: used > 0
                  ? 'In use — reassign those lists first'
                  : 'Delete',
              onPressed: used > 0 ? null : () => _confirmDelete(s),
            ),
    );
  }
}

/// Create / edit / clone form. Editing an in-use schedule re-anchors every
/// list that uses it against the new config (recurring gets a fresh
/// next_fire_at; items with series state keep it — lossless).
class ScheduleEditorScreen extends StatefulWidget {
  final Future<NotifDao?> Function() dao;
  final Future<void> Function() rearm;

  /// Custom row being edited; null when creating.
  final NotifScheduleRow? existing;

  /// Builtin (or custom) row to prefill from when creating a clone.
  final NotifScheduleRow? cloneOf;

  const ScheduleEditorScreen(
      {super.key,
      required this.dao,
      required this.rearm,
      this.existing,
      this.cloneOf});

  @override
  State<ScheduleEditorScreen> createState() => _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  static const _weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _offsetsCtrl;
  late final TextEditingController _intervalCtrl;
  String _kind = 'series';
  String _recurringMode = 'times'; // 'times' | 'interval'
  List<int> _times = [9 * 60]; // minutes after midnight
  Set<int> _days = {1, 2, 3, 4, 5, 6, 7}; // ISO: 1 = Monday
  int _perFire = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    final src = widget.existing ?? widget.cloneOf;
    var name = widget.existing?.name ??
        (widget.cloneOf != null ? 'Copy of ${widget.cloneOf!.name}' : '');
    var offsetsText = '1, 4, 17';
    var intervalText = '4';
    if (src != null) {
      _kind = src.kind;
      final config = jsonDecode(src.config) as Map<String, dynamic>;
      if (src.kind == 'series') {
        offsetsText = (config['offsets_waking_hours'] as List)
            .map((e) => '$e')
            .join(', ');
      } else {
        _perFire = (config['per_fire'] as int?) ?? 1;
        if (config.containsKey('every_waking_hours')) {
          _recurringMode = 'interval';
          intervalText = '${config['every_waking_hours']}';
        } else {
          _recurringMode = 'times';
          _times = [
            for (final t in config['times'] as List)
              int.parse((t as String).substring(0, 2)) * 60 +
                  int.parse(t.substring(3, 5))
          ];
          _days = {for (final d in config['days'] as List) d as int};
        }
      }
    }
    _nameCtrl = TextEditingController(text: name);
    _offsetsCtrl = TextEditingController(text: offsetsText);
    _intervalCtrl = TextEditingController(text: intervalText);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _offsetsCtrl.dispose();
    _intervalCtrl.dispose();
    super.dispose();
  }

  Map<String, Object?>? _buildConfig() {
    if (_kind == 'series') {
      final offsets = parseOffsetsText(_offsetsCtrl.text);
      if (offsets == null) {
        _error = 'Offsets must be numbers separated by commas.';
        return null;
      }
      return {'offsets_waking_hours': offsets};
    }
    if (_recurringMode == 'interval') {
      final every = double.tryParse(_intervalCtrl.text.trim());
      if (every == null) {
        _error = 'The interval must be a number of waking hours.';
        return null;
      }
      return {'every_waking_hours': every, 'per_fire': _perFire};
    }
    // Clock-anchored times inside the sleep window are an authoring error
    // the engine tolerates but the editor must block (spec §In-app UI).
    final w = NotifSettings.window;
    for (final t in _times) {
      if (insideSleepWindow(t, w)) {
        _error = '${minutesToHhmm(t)} is inside the sleep window '
            '(${minutesToHhmm(w.endMinutes)}–${minutesToHhmm(w.startMinutes)}).';
        return null;
      }
    }
    return {
      'times': [for (final t in (_times..sort())) minutesToHhmm(t)],
      'days': _days.toList()..sort(),
      'per_fire': _perFire,
    };
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final d = await widget.dao();
    if (d == null) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required.');
      return;
    }
    final config = _buildConfig();
    if (config == null) {
      setState(() {});
      return;
    }
    try {
      if (widget.existing == null) {
        await d.createCustomSchedule(name: name, kind: _kind, config: config);
      } else {
        final ok = await d.updateCustomSchedule(widget.existing!.id,
            name: name, kind: _kind, config: config);
        if (!ok) {
          setState(() => _error = 'Built-in schedules cannot be edited.');
          return;
        }
        // Re-anchor every list still on this schedule so next fire / due
        // times follow the new config immediately.
        final updated = await d.scheduleById(widget.existing!.id);
        final now = tz.TZDateTime.now(tz.local);
        for (final l in await d.listsUsingSchedule(widget.existing!.id)) {
          await applyScheduleToList(d, l, updated!, now, NotifSettings.window);
        }
      }
    } on ScheduleConfigError catch (e) {
      setState(() => _error = scheduleErrorMessage(e));
      return;
    }
    await widget.rearm();
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _addTime() async {
    final picked = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
    if (picked == null) return;
    setState(() {
      final m = picked.hour * 60 + picked.minute;
      if (!_times.contains(m)) _times = [..._times, m]..sort();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New schedule' : 'Edit schedule'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
                labelText: 'Name', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'series', label: Text('Spaced series')),
              ButtonSegment(value: 'recurring', label: Text('Recurring')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 16),
          if (_kind == 'series') ...[
            TextField(
              controller: _offsetsCtrl,
              decoration: const InputDecoration(
                labelText: 'Offsets (waking hours)',
                helperText: 'Strictly increasing, e.g. 1, 4, 17 — each item is '
                    're-notified after these many waking hours.',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ] else ...[
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'times', label: Text('Fixed times')),
                ButtonSegment(value: 'interval', label: Text('Interval')),
              ],
              selected: {_recurringMode},
              onSelectionChanged: (s) =>
                  setState(() => _recurringMode = s.first),
            ),
            const SizedBox(height: 16),
            if (_recurringMode == 'times') ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in _times)
                    InputChip(
                      label: Text(minutesToHhmm(t)),
                      onDeleted: _times.length > 1
                          ? () => setState(
                              () => _times = [..._times]..remove(t))
                          : null,
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Add time'),
                    onPressed: _addTime,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(_weekdayLabels[d - 1]),
                      selected: _days.contains(d),
                      onSelected: (sel) => setState(() {
                        final next = {..._days};
                        sel ? next.add(d) : next.remove(d);
                        _days = next;
                      }),
                    ),
                ],
              ),
            ] else
              TextField(
                controller: _intervalCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Every N waking hours',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Text('Items per fire')),
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: _perFire > 1
                      ? () => setState(() => _perFire--)
                      : null,
                ),
                Text('$_perFire'),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => setState(() => _perFire++),
                ),
              ],
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
