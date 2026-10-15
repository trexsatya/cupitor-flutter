import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The reader's single selection toolbar, shared by EPUB and DOCX.
class ReaderSelectionMenu extends StatelessWidget {
  const ReaderSelectionMenu({
    super.key,
    required this.anchor,
    required this.background,
    required this.foreground,
    required this.onDismiss,
    required this.onLookup,
    required this.onSearch,
    required this.onHighlight,
    required this.onNote,
    required this.onCopy,
  });

  final Offset anchor;
  final Color background;
  final Color foreground;
  final VoidCallback onDismiss;
  final VoidCallback onLookup;
  final VoidCallback onSearch;
  final VoidCallback onHighlight;
  final VoidCallback onNote;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: onDismiss,
        ),
      ),
      CustomSingleChildLayout(
        delegate: _MenuPosition(anchor),
        child: Material(
          key: const ValueKey('reader-selection-toolbar'),
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          color: background,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                _button(Icons.translate, 'Lookup', onLookup),
                _button(Icons.travel_explore, 'Search', onSearch),
                _button(Icons.brush, 'Highlight', onHighlight),
                _button(Icons.sticky_note_2_outlined, 'Note', onNote),
                _button(Icons.copy, 'Copy', onCopy),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _button(IconData icon, String label, VoidCallback onTap) => Expanded(
    child: Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: foreground, size: 22),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _MenuPosition extends SingleChildLayoutDelegate {
  _MenuPosition(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(
        width: math.min(360, math.max(0, constraints.maxWidth - 16)),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = anchor.dx - childSize.width / 2;
    final above = anchor.dy - childSize.height - 12;
    final top = above >= 8 ? above : anchor.dy + 32;
    return Offset(
      left.clamp(8.0, math.max(8.0, size.width - childSize.width - 8)),
      top.clamp(8.0, math.max(8.0, size.height - childSize.height - 8)),
    );
  }

  @override
  bool shouldRelayout(_MenuPosition oldDelegate) =>
      anchor != oldDelegate.anchor;
}
