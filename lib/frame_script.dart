/// Frame agents are cached across app updates. A bundled fix must not lose to
/// an older stored or CDN-cached copy on the first navigation after updating.
/// Bump the agent's version when a bundled fix must supersede older caches.
int frameScriptVersion(String script) => int.tryParse(
      RegExp(r'window\.__cupFrameBootVersion\s*=\s*(\d+)')
              .firstMatch(script)
              ?.group(1) ??
          '',
    ) ?? 0;

String preferFrameScript(String current, String? candidate) {
  if (candidate == null || candidate.trim().isEmpty) return current;
  return frameScriptVersion(candidate) >= frameScriptVersion(current)
      ? candidate
      : current;
}
