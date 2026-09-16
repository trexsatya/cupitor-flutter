import 'package:flutter/material.dart';

import 'db.dart';
import 'profile_manager.dart';
import 'profile_service.dart';
import 'tag_filter.dart';
import 'text_transform.dart';

/// Snapshot of every sentence-tagging toggle Dart owns. Passed into the
/// sheet which renders + calls back when the user changes anything.
class TagSettingsValues {
  final bool dbReady;
  final bool captureChipVisible;
  final bool masksVisible;
  final Set<int> filterTagIds;
  /// 'block' or 'document'. Hidden in surfaces that don't honor it
  /// (the EPUB reader uses its own per-sentence cup-sent wrappers, so
  /// the scope concept doesn't apply there).
  final String segmentationScope;
  final bool showSegmentation;
  /// Whether the text-transform engine is currently applying its
  /// per-language rules to the page. When off the sentences render
  /// with their original text (transforms are reverted).
  final bool transformsEnabled;
  /// When on, mask injections render the tagged sentence's attached
  /// image (if any) in place of the mask text. When no image is
  /// attached the mask text is used as usual. Only meaningful when
  /// masks are visible. Currently EPUB-only — hidden on surfaces that
  /// don't wire the JS entry point in.
  final bool showMaskImages;
  final bool showMaskImagesOption;
  /// Whether the playlist capture chip is currently visible in the
  /// EPUB reader. Independent of `captureChipVisible` (which controls
  /// the tag capture chip) — both can be enabled at once.
  final bool playlistChipVisible;
  /// Show the playlist section (toggle + "Manage playlists…" tile).
  /// EPUB-only for now; web hides it.
  final bool showPlaylistSection;
  const TagSettingsValues({
    required this.dbReady,
    required this.captureChipVisible,
    required this.masksVisible,
    required this.filterTagIds,
    required this.segmentationScope,
    required this.showSegmentation,
    this.transformsEnabled = true,
    this.showMaskImages = false,
    this.showMaskImagesOption = false,
    this.playlistChipVisible = false,
    this.showPlaylistSection = false,
  });
}

class TagSettingsCallbacks {
  final void Function(bool) onSetCaptureChipVisible;
  final void Function(bool) onSetMasksVisible;
  final Future<Set<int>?> Function() onOpenFilterSheet;
  final void Function(Set<int>) onApplyFilter;
  final void Function(String scope) onSetSegmentationScope;
  final VoidCallback onOpenBrowser;
  final void Function(bool)? onSetTransformsEnabled;
  final void Function(bool)? onSetShowMaskImages;
  final void Function(bool)? onSetPlaylistChipVisible;
  final VoidCallback? onOpenPlaylistScreen;
  /// EPUB-only. Opens the export flow for the currently-open book.
  final VoidCallback? onExportBook;
  /// Available on both surfaces — opens the notification manager.
  final VoidCallback? onOpenNotificationManager;
  const TagSettingsCallbacks({
    required this.onSetCaptureChipVisible,
    required this.onSetMasksVisible,
    required this.onOpenFilterSheet,
    required this.onApplyFilter,
    required this.onSetSegmentationScope,
    required this.onOpenBrowser,
    this.onSetTransformsEnabled,
    this.onSetShowMaskImages,
    this.onSetPlaylistChipVisible,
    this.onOpenPlaylistScreen,
    this.onExportBook,
    this.onOpenNotificationManager,
  });
}

/// Show the consolidated tag-feature settings sheet. The sheet is the
/// single entry point for the feature — `Capture chip` visibility,
/// `Show masks`, `Filter by tag`, `Sentence detection scope`, and
/// `Browse tagged sentences` all live here.
Future<void> showTagSettingsSheet({
  required BuildContext context,
  required TagSettingsValues initial,
  required TagSettingsCallbacks callbacks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _TagSettingsSheet(initial: initial, callbacks: callbacks),
  );
}

class _TagSettingsSheet extends StatefulWidget {
  final TagSettingsValues initial;
  final TagSettingsCallbacks callbacks;
  const _TagSettingsSheet({required this.initial, required this.callbacks});

  @override
  State<_TagSettingsSheet> createState() => _TagSettingsSheetState();
}

class _TagSettingsSheetState extends State<_TagSettingsSheet> {
  late bool _captureChipVisible;
  late bool _masksVisible;
  late Set<int> _filterTagIds;
  late String _scope;
  late bool _transformsEnabled;
  late bool _showMaskImages;
  late bool _playlistChipVisible;

  @override
  void initState() {
    super.initState();
    _captureChipVisible = widget.initial.captureChipVisible;
    _masksVisible = widget.initial.masksVisible;
    _filterTagIds = Set.of(widget.initial.filterTagIds);
    _scope = widget.initial.segmentationScope;
    _transformsEnabled = widget.initial.transformsEnabled;
    _showMaskImages = widget.initial.showMaskImages;
    _playlistChipVisible = widget.initial.playlistChipVisible;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.initial.dbReady) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Tag database not ready on this platform.',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    const Icon(Icons.label_outline),
                    const SizedBox(width: 8),
                    Text('Tag sentences', style: theme.textTheme.titleMedium),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _ProfilePickerRow(),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.touch_app_outlined),
                title: const Text('Show capture chip'),
                subtitle: const Text(
                  'A floating chip appears over the page. Tap it to arm; '
                  'tap a word to capture a sentence; long-press to hide.',
                ),
                value: _captureChipVisible,
                onChanged: (v) {
                  setState(() => _captureChipVisible = v);
                  widget.callbacks.onSetCaptureChipVisible(v);
                },
              ),
              SwitchListTile(
                secondary: Icon(_masksVisible ? Icons.visibility_off : Icons.visibility),
                title: const Text('Show tag masks'),
                subtitle: const Text(
                  'Render the mask in place of tagged sentences. '
                  'Long-press a masked sentence to edit it.',
                ),
                value: _masksVisible,
                onChanged: (v) {
                  setState(() => _masksVisible = v);
                  widget.callbacks.onSetMasksVisible(v);
                },
              ),
              if (widget.initial.showMaskImagesOption)
                SwitchListTile(
                  secondary: const Icon(Icons.image_outlined),
                  title: const Text('Show maskover pictures'),
                  subtitle: const Text(
                    'When a tagged sentence has an image attached, render '
                    'the image in place of its mask text (only while masks '
                    'are shown).',
                  ),
                  value: _showMaskImages,
                  onChanged: (v) {
                    setState(() => _showMaskImages = v);
                    widget.callbacks.onSetShowMaskImages?.call(v);
                  },
                ),
              if (widget.callbacks.onSetTransformsEnabled != null)
                SwitchListTile(
                  secondary: const Icon(Icons.transform),
                  title: const Text('Apply transformations'),
                  subtitle: const Text(
                    'Rewrite text on the page using the per-language rules. '
                    'Turn off to see the source text as-is.',
                  ),
                  value: _transformsEnabled,
                  onChanged: (v) {
                    setState(() => _transformsEnabled = v);
                    widget.callbacks.onSetTransformsEnabled!(v);
                  },
                ),
              ListTile(
                leading: Icon(_filterTagIds.isEmpty
                    ? Icons.filter_alt_outlined : Icons.filter_alt),
                title: const Text('Filter by tag'),
                subtitle: Text(
                  _filterTagIds.isEmpty
                      ? 'No filter active'
                      : 'Filtering by ${_filterTagIds.length} tag(s)',
                ),
                trailing: _filterTagIds.isEmpty
                    ? null
                    : TextButton(
                        child: const Text('Clear'),
                        onPressed: () {
                          setState(() => _filterTagIds = <int>{});
                          widget.callbacks.onApplyFilter(<int>{});
                        },
                      ),
                onTap: () async {
                  final result = await widget.callbacks.onOpenFilterSheet();
                  if (result != null) {
                    setState(() => _filterTagIds = result);
                  }
                },
              ),
              if (widget.initial.showSegmentation) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    'Sentence detection',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                RadioListTile<String>(
                  value: 'block',
                  groupValue: _scope,
                  title: const Text('Block (default)'),
                  subtitle: const Text(
                    'A sentence is detected within the tapped word\'s '
                    'nearest block. Fast; correct for most sites.',
                  ),
                  onChanged: (v) => _setScope(v),
                ),
                RadioListTile<String>(
                  value: 'document',
                  groupValue: _scope,
                  title: const Text('Whole page'),
                  subtitle: const Text(
                    'A sentence is detected across the whole document. Use '
                    'this on sites that wrap each printed line in its own '
                    'block (e.g. some Angular SPAs) — sentences span '
                    'many blocks and the default scope captures only a '
                    'fragment.',
                  ),
                  onChanged: (v) => _setScope(v),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('Browse tagged sentences'),
                subtitle: const Text(
                  'Defaults to this page; toggle "All pages" inside.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).pop();
                  widget.callbacks.onOpenBrowser();
                },
              ),
              ListTile(
                leading: const Icon(Icons.transform),
                title: const Text('Transformations'),
                subtitle: const Text(
                  'Per-language rules that rewrite text on the page. '
                  'Original text is preserved for tagging.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  Navigator.of(context).pop();
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const TransformationsScreen(),
                  ));
                },
              ),
              if (widget.initial.showPlaylistSection) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    'Playlist',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (widget.callbacks.onSetPlaylistChipVisible != null)
                  SwitchListTile(
                    secondary: const Icon(Icons.playlist_add),
                    title: const Text('Show "Add to playlist" chip'),
                    subtitle: const Text(
                      'A second floating chip. When armed, tapping a sentence '
                      'appends it to the active playlist instead of opening '
                      'the tag dialog.',
                    ),
                    value: _playlistChipVisible,
                    onChanged: (v) {
                      setState(() => _playlistChipVisible = v);
                      widget.callbacks.onSetPlaylistChipVisible!(v);
                    },
                  ),
                if (widget.callbacks.onOpenPlaylistScreen != null)
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: const Text('Manage playlists'),
                    subtitle: const Text(
                      'Create playlists, reorder / delete cards, and pick the '
                      'active playlist for capture.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.callbacks.onOpenPlaylistScreen!();
                    },
                  ),
              ],
              if (widget.callbacks.onOpenNotificationManager != null) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child:
                      Text('Notifications', style: theme.textTheme.titleSmall),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('Notification manager'),
                  subtitle: const Text(
                    'Review lists, schedules, the waking window, and the '
                    'per-fire cap.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.callbacks.onOpenNotificationManager!();
                  },
                ),
              ],
              if (widget.callbacks.onExportBook != null) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('Storage', style: theme.textTheme.titleSmall),
                ),
                if (widget.callbacks.onExportBook != null)
                  ListTile(
                    leading: const Icon(Icons.file_upload_outlined),
                    title: const Text('Export book (with all data)'),
                    subtitle: const Text(
                      'Bundle the EPUB plus every tag, media attachment, '
                      'and playlist item that references it into a portable '
                      '.cupitor.zip you can import on another device.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.callbacks.onExportBook!();
                    },
                  ),
              ],
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  void _setScope(String? v) {
    if (v == null || v == _scope) return;
    setState(() => _scope = v);
    widget.callbacks.onSetSegmentationScope(v);
  }
}

/// Row at the top of the settings sheet showing the current profile
/// with a popup picker + a "Manage…" affordance that opens the full
/// profile management screen. Subscribes to [ProfileService.active] so
/// the displayed name stays in sync with renames / switches done from
/// the management screen.
class _ProfilePickerRow extends StatefulWidget {
  @override
  State<_ProfilePickerRow> createState() => _ProfilePickerRowState();
}

class _ProfilePickerRowState extends State<_ProfilePickerRow> {
  List<ProfileRow> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await CupitorDb.instance.listProfiles();
    if (!mounted) return;
    setState(() => _profiles = list);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ProfileRow?>(
      valueListenable: ProfileService.active,
      builder: (_, active, __) {
        return ListTile(
          leading: const Icon(Icons.workspaces_outline),
          title: const Text('Profile'),
          subtitle: Text(active?.name ?? 'Default'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_profiles.length > 1)
                PopupMenuButton<int>(
                  icon: const Icon(Icons.unfold_more),
                  tooltip: 'Switch profile',
                  onSelected: (id) async {
                    await ProfileService.setActive(id);
                  },
                  itemBuilder: (_) => _profiles
                      .map((p) => PopupMenuItem<int>(
                            value: p.id,
                            child: Row(
                              children: [
                                Icon(
                                  p.id == active?.id
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Text(p.name),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: 'Manage profiles',
                onPressed: () async {
                  Navigator.of(context).pop();
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const ProfileManagementScreen(),
                  ));
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Convenience: a single IconButton that opens the settings sheet.
/// Same icon as the current "Tag sentences" entry — used by both
/// surfaces as the one button the user asked for.
class TagSettingsButton extends StatelessWidget {
  final TagSettingsValues Function() valuesProvider;
  final TagSettingsCallbacks callbacks;
  final Color? color;
  const TagSettingsButton({
    super.key,
    required this.valuesProvider,
    required this.callbacks,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.label_outline),
      tooltip: 'Tag sentences',
      color: color,
      onPressed: () => showTagSettingsSheet(
        context: context,
        initial: valuesProvider(),
        callbacks: callbacks,
      ),
    );
  }
}
