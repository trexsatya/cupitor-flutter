import 'package:flutter/material.dart';

import 'db.dart';
import 'profile_service.dart';

class ProfileManagementScreen extends StatefulWidget {
  const ProfileManagementScreen({super.key});

  @override
  State<ProfileManagementScreen> createState() => _ProfileManagementScreenState();
}

class _ProfileManagementScreenState extends State<ProfileManagementScreen> {
  List<ProfileRow> _profiles = const [];
  // Per-profile stats — keyed by profile id.
  final Map<int, ({int tagCount, int sentenceCount})> _stats = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await CupitorDb.instance.listProfiles();
    _stats.clear();
    for (final p in list) {
      _stats[p.id] = await CupitorDb.instance.profileStats(p.id);
    }
    if (!mounted) return;
    setState(() {
      _profiles = list;
      _loading = false;
    });
  }

  Future<void> _create() async {
    final name = await _promptName(title: 'New profile');
    if (name == null || name.isEmpty) return;
    final created = await CupitorDb.instance.createProfile(name);
    if (!mounted) return;
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name already exists or is empty')),
      );
      return;
    }
    await ProfileService.setActive(created.id);
    await _load();
  }

  Future<void> _rename(ProfileRow p) async {
    final name = await _promptName(title: 'Rename profile', initial: p.name);
    if (name == null || name.isEmpty || name == p.name) return;
    final ok = await CupitorDb.instance.renameProfile(p.id, name);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rename failed — name might be taken')),
      );
      return;
    }
    await ProfileService.refresh();
    await _load();
  }

  Future<void> _delete(ProfileRow p) async {
    if (_profiles.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the only remaining profile.')),
      );
      return;
    }
    if (p.id == ProfileService.currentId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Switch to another profile first.')),
      );
      return;
    }
    final stats = _stats[p.id] ?? (tagCount: 0, sentenceCount: 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete profile "${p.name}"?'),
        content: Text(
          'This removes ${stats.tagCount} tag${stats.tagCount == 1 ? '' : 's'} '
          'and ${stats.sentenceCount} tagged sentence${stats.sentenceCount == 1 ? '' : 's'}. '
          'The book and webpage text itself is untouched.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await CupitorDb.instance.deleteProfile(p.id);
    await _load();
  }

  Future<String?> _promptName({required String title, String initial = ''}) async {
    final ctrl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Profile name',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(ctx).pop(ctrl.text.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profiles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New profile',
            onPressed: _create,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<ProfileRow?>(
              valueListenable: ProfileService.active,
              builder: (_, active, __) {
                return ListView.separated(
                  itemCount: _profiles.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final p = _profiles[i];
                    final isActive = active?.id == p.id;
                    final s = _stats[p.id];
                    return ListTile(
                      leading: Icon(
                        isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: isActive ? Theme.of(context).colorScheme.primary : null,
                      ),
                      title: Text(
                        p.name,
                        style: TextStyle(fontWeight: isActive ? FontWeight.w600 : FontWeight.w400),
                      ),
                      subtitle: s == null
                          ? null
                          : Text(
                              '${s.tagCount} tag${s.tagCount == 1 ? '' : 's'} · '
                              '${s.sentenceCount} sentence${s.sentenceCount == 1 ? '' : 's'}',
                            ),
                      onTap: () async {
                        await ProfileService.setActive(p.id);
                        if (!mounted) return;
                        setState(() {});
                      },
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'rename') _rename(p);
                          if (v == 'delete') _delete(p);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
