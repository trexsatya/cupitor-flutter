import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-managed list of URL patterns for which the main WebView's
/// word-lookup / sentence-tagging JS should NOT be injected.
///
/// Match rule: case-insensitive substring — pattern `youtube.com`
/// matches every YouTube page, `docs.google.com/spreadsheet` matches
/// only spreadsheets. Kept simple because that covers 90 % of "leave
/// this site alone" cases without dragging in glob / regex UX.
///
/// Persisted under `lookupExcludedPatterns` in SharedPreferences.
/// Exposed as a `ValueNotifier` so the settings screen and the caller
/// see the same list; the caller (`_injectJs`) reads
/// `LookupExclusions.matches(url)` on every page load.
class LookupExclusions {
  LookupExclusions._();

  static const String _kPrefKey = 'lookupExcludedPatterns';

  /// Current pattern list. Never null; each element is a non-empty,
  /// trimmed, lowercased string.
  static final ValueNotifier<List<String>> patterns =
      ValueNotifier<List<String>>(const []);

  static bool _initialized = false;

  /// Load persisted patterns once at app startup. Idempotent.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_kPrefKey) ?? const [];
      patterns.value = _normalize(stored);
    } catch (_) {
      // Best-effort — leave the empty default in place.
    }
  }

  /// True if [url] matches at least one pattern. Empty pattern list =
  /// nothing excluded.
  static bool matches(String url) {
    final list = patterns.value;
    if (list.isEmpty || url.isEmpty) return false;
    final lower = url.toLowerCase();
    for (final p in list) {
      if (p.isNotEmpty && lower.contains(p)) return true;
    }
    return false;
  }

  /// Add [pattern] (trimmed / lowercased). Duplicates ignored.
  /// Returns true if the list actually changed.
  static Future<bool> add(String pattern) async {
    final p = pattern.trim().toLowerCase();
    if (p.isEmpty) return false;
    final cur = List<String>.from(patterns.value);
    if (cur.contains(p)) return false;
    cur.add(p);
    patterns.value = cur;
    await _persist();
    return true;
  }

  /// Remove [pattern] (exact match against the normalized value).
  /// Returns true if the list actually changed.
  static Future<bool> remove(String pattern) async {
    final p = pattern.trim().toLowerCase();
    if (p.isEmpty) return false;
    final cur = List<String>.from(patterns.value);
    if (!cur.remove(p)) return false;
    patterns.value = cur;
    await _persist();
    return true;
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kPrefKey, patterns.value);
    } catch (_) { /* best effort */ }
  }

  static List<String> _normalize(List<String> raw) {
    final out = <String>[];
    final seen = <String>{};
    for (final s in raw) {
      final t = s.trim().toLowerCase();
      if (t.isEmpty || !seen.add(t)) continue;
      out.add(t);
    }
    return out;
  }
}

/// Management screen: list current patterns, add new ones via a text
/// field at the top, delete existing ones via a trailing icon.
class LookupExclusionsScreen extends StatefulWidget {
  const LookupExclusionsScreen({super.key});

  @override
  State<LookupExclusionsScreen> createState() => _LookupExclusionsScreenState();
}

class _LookupExclusionsScreenState extends State<LookupExclusionsScreen> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final added = await LookupExclusions.add(text);
    _input.clear();
    if (!mounted) return;
    if (!added) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pattern already in the list')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Lookup exclusions')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'URLs whose page will NOT have word-lookup / sentence-tagging '
              'JS injected. Matches by case-insensitive substring — enter a '
              'hostname (e.g. youtube.com) or any URL fragment.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      labelText: 'Add pattern',
                      hintText: 'e.g. youtube.com',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<List<String>>(
              valueListenable: LookupExclusions.patterns,
              builder: (_, list, __) {
                if (list.isEmpty) {
                  return Center(
                    child: Text(
                      'No exclusions yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 0),
                  itemBuilder: (_, i) {
                    final p = list[i];
                    return ListTile(
                      leading: const Icon(Icons.block),
                      title: Text(p),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                        tooltip: 'Remove',
                        onPressed: () => LookupExclusions.remove(p),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
