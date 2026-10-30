import 'package:flutter/material.dart';

import 'youtube_sidebar_subtitles.dart';

/// Kept on the page beside the existing video chips, independent of the
/// auto-hidden app bar and the remotely injected subtitle panel.
class MainSubtitleCaptureButton extends StatelessWidget {
  const MainSubtitleCaptureButton({
    super.key,
    required this.address,
    required this.onPressed,
  });

  final TextEditingController address;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: address,
    builder: (context, value, _) {
      if (youtubeSubtitleVideoId(value.text) == null) {
        return const SizedBox.shrink();
      }
      return Positioned(
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 318,
        child: FloatingActionButton.small(
          heroTag: 'main-subtitle-capture',
          tooltip: 'Choose caption track',
          onPressed: onPressed,
          child: const Icon(Icons.closed_caption_outlined),
        ),
      );
    },
  );
}
