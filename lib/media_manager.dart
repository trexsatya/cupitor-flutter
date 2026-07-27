import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'db.dart';
import 'media_store.dart';

/// Global browser for every media attachment in a profile. Reached
/// from the tag browser's app bar. Reuses [MediaRow] + [MediaStore]
/// so this screen has no persistence of its own — it just presents
/// what the capture sheet has been writing.
///
/// Tap opens a preview (image / URL open); the trash icon removes
/// the media row from its sentence and gcs the on-disk file when
/// it becomes an orphan. The overflow menu exposes a one-shot
/// "cleanup orphaned files" action that scans the store for files
/// no live row references and deletes them.
class MediaManagerScreen extends StatefulWidget {
  final int profileId;
  final void Function(String surface, String locator)? onNavigateToSentence;
  const MediaManagerScreen({
    super.key,
    required this.profileId,
    this.onNavigateToSentence,
  });

  @override
  State<MediaManagerScreen> createState() => _MediaManagerScreenState();
}

class _MediaManagerScreenState extends State<MediaManagerScreen> {
  bool _loading = true;
  List<MediaWithSentenceRow> _all = const [];
  String _filter = 'all'; // 'all' | 'image' | 'audio' | 'video' | 'link' | 'url'
  final TextEditingController _searchCtrl = TextEditingController();

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
    final rows = await CupitorDb.instance.listAllMediaForProfile(widget.profileId);
    if (!mounted) return;
    setState(() {
      _all = rows;
      _loading = false;
    });
  }

  List<MediaWithSentenceRow> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _all.where((r) {
      final m = r.media;
      if (_filter == 'url' && !m.isUrl) return false;
      if (_filter != 'all' && _filter != 'url' && m.kind != _filter) return false;
      if (q.isEmpty) return true;
      if (m.filename.toLowerCase().contains(q)) return true;
      if ((m.url ?? '').toLowerCase().contains(q)) return true;
      if (r.sentenceText.toLowerCase().contains(q)) return true;
      if ((r.sentenceMask ?? '').toLowerCase().contains(q)) return true;
      if ((r.pageTitle ?? '').toLowerCase().contains(q)) return true;
      return false;
    }).toList(growable: false);
  }

  Future<void> _delete(MediaWithSentenceRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove attachment?'),
        content: Text(
          row.media.isUrl
              ? 'The URL will be detached from its sentence. The link itself is external and is not affected.'
              : 'The attachment will be removed from its sentence. The file on disk is kept only as long as some other tagged sentence still references it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final orphan = await CupitorDb.instance.deleteMediaReturningOrphanSha1(row.media.id);
    if (orphan != null) {
      await MediaStore.instance.deleteFile(orphan);
    }
    if (!mounted) return;
    setState(() {
      _all = _all.where((r) => r.media.id != row.media.id).toList(growable: false);
    });
  }

  Future<void> _preview(MediaWithSentenceRow row) async {
    final m = row.media;
    if (m.isUrl) {
      await _showUrlPreview(url: m.url!, kind: m.kind, label: m.filename);
      return;
    }
    final ext = _extOf(m.filename);
    final file = await MediaStore.instance.resolve(m.sha1, extension: ext);
    if (!mounted) return;
    if (file == null || !await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File is missing on disk.')),
      );
      return;
    }
    if (!mounted) return;
    await _showFilePreview(file: file, kind: m.kind, label: m.filename);
  }

  Future<void> _showFilePreview({
    required File file,
    required String kind,
    required String label,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(ctx).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            if (kind == 'image')
              Padding(
                padding: const EdgeInsets.all(8),
                child: InteractiveViewer(
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Could not display image.'),
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      kind == 'audio' ? Icons.audiotrack : Icons.videocam,
                      size: 64,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      kind == 'audio' ? 'Audio attachment' : 'Video attachment',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'In-app playback not yet supported. The file is preserved '
                      'with its sentence.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showUrlPreview({
    required String url,
    required String kind,
    required String label,
  }) async {
    IconData icon;
    switch (kind) {
      case 'image': icon = Icons.image_outlined; break;
      case 'audio': icon = Icons.audiotrack; break;
      case 'video': icon = Icons.videocam_outlined; break;
      default: icon = Icons.link;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('External URL:', style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 4),
            SelectableText(url, style: Theme.of(ctx).textTheme.bodyMedium),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await _openUrl(url);
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open'),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No app available to open this URL.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open URL: $e')),
        );
      }
    }
  }

  Future<void> _cleanupOrphans() async {
    final referenced = await CupitorDb.instance.referencedFileSha1s();
    final removed = await MediaStore.instance.deleteOrphans(referenced);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed == 0
              ? 'No orphaned files found.'
              : 'Removed $removed orphaned file${removed == 1 ? '' : 's'}.',
        ),
      ),
    );
  }

  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Media manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () { setState(() => _loading = true); _load(); },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'orphans') _cleanupOrphans();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'orphans',
                child: ListTile(
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('Clean up orphan files'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildFilterBar(theme),
                if (filtered.isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _all.isEmpty
                              ? 'No media attached yet.\nAttach images, audio, video, or links from the capture sheet.'
                              : 'No attachments match your filters.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _buildRow(filtered[i], theme),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    Widget chip(String value, String label, IconData? icon) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          avatar: icon == null ? null : Icon(icon, size: 16),
          label: Text(label),
          selected: _filter == value,
          onSelected: (_) => setState(() => _filter = value),
        ),
      );
    }
    return Material(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  chip('all', 'All', null),
                  chip('image', 'Images', Icons.image_outlined),
                  chip('audio', 'Audio', Icons.audiotrack),
                  chip('video', 'Video', Icons.videocam_outlined),
                  chip('url', 'URL', Icons.link),
                ],
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search filename, URL, sentence, or page…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '${_filtered.length} of ${_all.length} attachment${_all.length == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(MediaWithSentenceRow row, ThemeData theme) {
    final m = row.media;
    return Dismissible(
      key: ValueKey('media-${m.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: Icon(Icons.delete, color: theme.colorScheme.onError),
      ),
      confirmDismiss: (_) async {
        await _delete(row);
        return false;  // We handle removal via setState in _delete.
      },
      child: InkWell(
        onTap: () => _preview(row),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildThumbnail(m, theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _kindBadge(m, theme),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            m.filename.isEmpty ? (m.url ?? 'Attachment') : m.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if ((m.url ?? '').isNotEmpty && m.url != m.filename) ...[
                      const SizedBox(height: 2),
                      Text(
                        m.url!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      row.sentenceText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          row.pageSurface == 'web' ? Icons.public : Icons.menu_book_outlined,
                          size: 12,
                          color: theme.hintColor,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            row.pageTitle?.isNotEmpty == true
                                ? row.pageTitle!
                                : row.pageLocator,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (widget.onNavigateToSentence != null && row.pageSurface == 'web')
                IconButton(
                  icon: const Icon(Icons.launch, size: 18),
                  tooltip: 'Open page',
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onNavigateToSentence!(row.pageSurface, row.pageLocator);
                  },
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: theme.colorScheme.error,
                tooltip: 'Delete',
                onPressed: () => _delete(row),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(MediaRow m, ThemeData theme) {
    const size = 56.0;
    Widget content;
    if (!m.isUrl && m.kind == 'image') {
      content = FutureBuilder<File?>(
        future: MediaStore.instance.resolve(m.sha1, extension: _extOf(m.filename)),
        builder: (_, snap) {
          final f = snap.data;
          if (f == null) {
            return Center(child: Icon(Icons.image_outlined, color: theme.colorScheme.primary));
          }
          return Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Center(
              child: Icon(Icons.image_outlined, color: theme.colorScheme.primary),
            ),
          );
        },
      );
    } else {
      IconData icon;
      switch (m.kind) {
        case 'audio': icon = Icons.audiotrack; break;
        case 'video': icon = Icons.videocam_outlined; break;
        case 'image': icon = Icons.image_outlined; break;
        default: icon = Icons.link;
      }
      content = Center(child: Icon(icon, size: 28, color: theme.colorScheme.primary));
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.hardEdge,
      child: content,
    );
  }

  Widget _kindBadge(MediaRow m, ThemeData theme) {
    final label = m.isUrl ? 'url' : m.kind;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
