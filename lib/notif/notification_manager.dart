import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

import '../db.dart';
import '../profile_service.dart';
import 'notif_dao.dart';
import 'notif_list_screen.dart';
import 'notif_ops.dart';
import 'notif_runtime.dart';
import 'notif_settings.dart';
import 'notif_ui_util.dart';
import 'schedule_editor.dart';

/// Top-level notifications screen (spec §In-app UI): global settings
/// (waking window, per-fire cap, custom schedules) and the list index.
/// All deps are constructor-injectable for widget tests; the defaults wire
/// the real runtime.
class NotificationManagerScreen extends StatefulWidget {
  final Future<NotifDao?> Function()? dao;
  final Future<void> Function()? rearm;
  final Future<String> Function()? permissionStatus;
  final Future<String> Function()? requestPermission;
  final int Function()? profileId;
  const NotificationManagerScreen(
      {super.key,
      this.dao,
      this.rearm,
      this.permissionStatus,
      this.requestPermission,
      this.profileId});

  @override
  State<NotificationManagerScreen> createState() =>
      _NotificationManagerScreenState();
}

class _ListSummary {
  final NotifListRow list;
  final String scheduleName;
  final int itemCount;
  final int? nextFireMs;
  const _ListSummary(this.list, this.scheduleName, this.itemCount, this.nextFireMs);
}

class _NotificationManagerScreenState extends State<NotificationManagerScreen> {
  late final Future<NotifDao?> Function() _dao =
      widget.dao ?? () => CupitorDb.instance.notifDao();
  late final Future<void> Function() _rearm =
      widget.rearm ?? notifService.rearm;
  late final Future<String> Function() _permissionStatus =
      widget.permissionStatus ?? notifChannel.permissionStatus;
  late final Future<String> Function() _requestPermission =
      widget.requestPermission ?? notifChannel.requestPermission;
  late final int Function() _profileId =
      widget.profileId ?? () => ProfileService.currentId;

  bool _loading = true;
  bool _unsupported = false;
  String _permission = 'unknown';
  List<_ListSummary> _lists = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final permission = await _permissionStatus();
    final d = await _dao();
    if (d == null) {
      if (!mounted) return;
      setState(() {
        _unsupported = true;
        _permission = permission;
        _loading = false;
      });
      return;
    }
    final rows = await d.listsForProfile(_profileId());
    final out = <_ListSummary>[];
    for (final l in rows) {
      final schedule =
          l.scheduleId == null ? null : await d.scheduleById(l.scheduleId!);
      final items = await d.itemsForList(l.id);
      int? nextFire = l.nextFireAt;
      if (schedule?.kind == 'series') {
        // Series lists fire per item: show the soonest active due time.
        for (final i in items) {
          if (i.status != 'active' || i.nextDueAt == null) continue;
          if (nextFire == null || i.nextDueAt! < nextFire) nextFire = i.nextDueAt;
        }
      }
      out.add(_ListSummary(
          l, schedule?.name ?? 'No schedule', items.length, nextFire));
    }
    if (!mounted) return;
    setState(() {
      _permission = permission;
      _lists = out;
      _loading = false;
    });
  }

  Future<void> _onRequestPermission() async {
    final result = await _requestPermission();
    await _rearm();
    await _load();
    if (result == 'granted' || !mounted) return;
    // Android 13+ never re-prompts after a permanent denial — point at the
    // system settings instead (iOS/macOS get a real deep-link).
    final opened = await launchUrl(Uri.parse('app-settings:'))
        .catchError((_) => false);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Enable notifications for Cupitor in system settings.')));
    }
  }

  Future<void> _editWindow() async {
    final w = NotifSettings.window;
    final start = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: w.startMinutes ~/ 60, minute: w.startMinutes % 60),
      helpText: 'Waking window start (wake up)',
    );
    if (start == null || !mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: w.endMinutes ~/ 60, minute: w.endMinutes % 60),
      helpText: 'Waking window end (bedtime)',
    );
    if (end == null || !mounted) return;
    final startM = start.hour * 60 + start.minute;
    final endM = end.hour * 60 + end.minute;
    // The editor blocks the degenerate (always-awake) and inverted windows
    // the engine merely tolerates (spec §In-app UI validation).
    if (startM >= endM) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(startM == endM
              ? 'Start and end must differ.'
              : 'Wake-up must be earlier than bedtime.')));
      return;
    }
    await NotifSettings.setWindow(minutesToHhmm(startM), minutesToHhmm(endM));
    await _rearm(); // spec: settings change is a re-arm trigger
    if (mounted) setState(() {});
  }

  Future<void> _setCap(int cap) async {
    await NotifSettings.setPerFireCap(cap);
    await _rearm(); // spec: settings change is a re-arm trigger
    if (mounted) setState(() {});
  }

  Future<void> _createList() async {
    final d = await _dao();
    if (d == null) return;
    final nameCtrl = TextEditingController();
    final schedules = await d.listSchedules();
    if (!mounted) return;
    if (schedules.isEmpty) {
      // Only possible if the builtin seed failed — degrade, don't throw.
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No schedules available.')));
      return;
    }
    NotifScheduleRow selected = schedules.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New notification list'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<NotifScheduleRow>(
                value: selected,
                decoration: const InputDecoration(
                    labelText: 'Schedule',
                    border: OutlineInputBorder(),
                    isDense: true),
                items: [
                  for (final s in schedules)
                    DropdownMenuItem(value: s, child: Text(s.name)),
                ],
                onChanged: (s) =>
                    setDialogState(() => selected = s ?? selected),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Create')),
          ],
        ),
      ),
    );
    final name = nameCtrl.text.trim();
    if (ok != true || name.isEmpty) return;
    final now = tz.TZDateTime.now(tz.local);
    await d.createList(
      profileId: _profileId(),
      name: name,
      source: 'app',
      scheduleId: selected.id,
      nextFireAt: initialNextFireMs(selected, now, NotifSettings.window),
    );
    await _rearm();
    await _load();
  }

  Future<void> _openList(int listId) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NotifListScreen(listId: listId, dao: _dao, rearm: _rearm),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (!_unsupported)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New list',
              onPressed: _createList,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _unsupported
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'Notifications are not available on this platform.'),
                  ),
                )
              : ListView(
                  children: [
                    if (_permission == 'denied')
                      _permissionBanner(theme),
                    _sectionHeader(theme, 'Settings'),
                    ListTile(
                      leading: const Icon(Icons.bedtime_outlined),
                      title: const Text('Waking window'),
                      subtitle: Text(
                          '${minutesToHhmm(NotifSettings.window.startMinutes)}'
                          ' – '
                          '${minutesToHhmm(NotifSettings.window.endMinutes)}'
                          ' · nothing fires outside it'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _editWindow,
                    ),
                    ListTile(
                      leading: const Icon(Icons.filter_5_outlined),
                      title: const Text('Max notifications per fire'),
                      subtitle:
                          const Text('Overflow waits for the next slot.'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: NotifSettings.perFireCap > 1
                                ? () => _setCap(NotifSettings.perFireCap - 1)
                                : null,
                          ),
                          Text('${NotifSettings.perFireCap}'),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: NotifSettings.perFireCap < 20
                                ? () => _setCap(NotifSettings.perFireCap + 1)
                                : null,
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: const Text('Schedules'),
                      subtitle: const Text(
                          'Built-in spaced-repetition ladders and your custom '
                          'schedules.'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) =>
                              ScheduleListScreen(dao: _dao, rearm: _rearm),
                        ));
                        await _load();
                      },
                    ),
                    const Divider(height: 1),
                    _sectionHeader(theme, 'Lists'),
                    if (_lists.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No notification lists yet. Tap + to create one, or '
                          'let the language webpage create them.',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.hintColor),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      for (final s in _lists) _listTile(theme, s),
                  ],
                ),
    );
  }

  Widget _permissionBanner(ThemeData theme) {
    return MaterialBanner(
      backgroundColor: theme.colorScheme.errorContainer,
      leading: Icon(Icons.notifications_off_outlined,
          color: theme.colorScheme.onErrorContainer),
      content: Text(
        'Notification permission is denied — lists are kept but nothing '
        'will fire.',
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
      actions: [
        TextButton(
          onPressed: _onRequestPermission,
          child: const Text('Enable'),
        ),
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: theme.textTheme.titleSmall),
      );

  Widget _listTile(ThemeData theme, _ListSummary s) {
    final paused = s.list.status == 'paused';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return ListTile(
      leading: Icon(
        paused ? Icons.pause_circle_outline : Icons.notifications_active_outlined,
        color: paused ? theme.disabledColor : null,
      ),
      title: Text(s.list.name),
      subtitle: Text([
        s.scheduleName,
        '${s.itemCount} item${s.itemCount == 1 ? '' : 's'}',
        paused ? 'paused' : 'next ${formatDue(s.nextFireMs, nowMs)}',
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openList(s.list.id),
    );
  }
}
