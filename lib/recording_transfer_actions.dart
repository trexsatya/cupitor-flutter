import 'package:flutter/material.dart';

/// Kept in both app-bar modes so export follows the visible selection.
class RecordingTransferActions extends StatelessWidget {
  const RecordingTransferActions({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.busy,
    required this.onExport,
    required this.onImport,
  });

  final int selectedCount;
  final int totalCount;
  final bool busy;
  final VoidCallback onExport;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        icon: const Icon(Icons.file_download_outlined),
        tooltip: selectedCount > 0
            ? 'Export selected recordings'
            : 'Export all recordings',
        onPressed: busy || totalCount == 0 ? null : onExport,
      ),
      if (selectedCount == 0)
        IconButton(
          icon: const Icon(Icons.file_upload_outlined),
          tooltip: 'Import recordings',
          onPressed: busy ? null : onImport,
        ),
    ],
  );
}
