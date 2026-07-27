import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single transformation rule. Two shapes are supported:
///
/// - `substring` — replace every occurrence of [pattern] inside any word
///   with [replacement]. Case-sensitive. Matches within a single token
///   (does NOT span whitespace).
/// - `sequence` — match a run of consecutive word tokens. [pattern] is a
///   whitespace-separated list where the literal token `[]` (or `_`)
///   stands for "any single word" and is copied verbatim into the
///   replacement's matching `[]` slot.
class TransformRule {
  final String type; // 'substring' | 'sequence'
  final String pattern;
  final String replacement;
  /// When true (default) the pattern only matches when its edges are
  /// on token boundaries — "af" won't rewrite "afton" because 't' is
  /// still a letter. When false, the pattern matches anywhere inside
  /// a token (the old substring behavior). Only meaningful for the
  /// `substring` rule type; sequence rules are inherently token-aligned.
  final bool wholeWord;
  const TransformRule({
    required this.type,
    required this.pattern,
    required this.replacement,
    this.wholeWord = true,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'pattern': pattern,
        'replacement': replacement,
        'wholeWord': wholeWord,
      };

  factory TransformRule.fromJson(Map<String, dynamic> m) => TransformRule(
        type: (m['type'] as String?) ?? 'substring',
        pattern: (m['pattern'] as String?) ?? '',
        replacement: (m['replacement'] as String?) ?? '',
        // Historical rules (written before this field existed) load with
        // wholeWord=true so a stale "af → av" doesn't keep rewriting
        // "afton" after this build ships.
        wholeWord: (m['wholeWord'] as bool?) ?? true,
      );
}

/// Persisted rule set keyed by primary language subtag ("sv", "en", …).
class TransformRuleStore {
  static const _prefsKey = 'xformRules';

  /// Load the full rule set. Returns an empty map on first run.
  static Future<Map<String, List<TransformRule>>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, List<TransformRule>>{};
      decoded.forEach((lang, rules) {
        if (rules is List) {
          out[lang] = rules
              .whereType<Map>()
              .map((r) => TransformRule.fromJson(r.cast<String, dynamic>()))
              .toList();
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveAll(Map<String, List<TransformRule>> data) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode({
      for (final entry in data.entries)
        entry.key: entry.value.map((r) => r.toJson()).toList(),
    });
    await prefs.setString(_prefsKey, encoded);
  }

  /// Convenience: rules for a single language, empty list if none.
  static Future<List<TransformRule>> loadFor(String lang) async {
    final all = await loadAll();
    return all[lang] ?? const [];
  }

  static Future<void> saveFor(String lang, List<TransformRule> rules) async {
    final all = await loadAll();
    all[lang] = rules;
    await saveAll(all);
  }
}

/// Serializes the rule set to JSON for the JS engine to consume. The
/// engine expects the same shape as [TransformRule.toJson].
String rulesToJsPayload(List<TransformRule> rules) =>
    jsonEncode(rules.map((r) => r.toJson()).toList());

/// Full-screen editor for all transformation rules. Grouped by language
/// with a picker so you can build a rule set once per language.
class TransformationsScreen extends StatefulWidget {
  const TransformationsScreen({super.key});

  @override
  State<TransformationsScreen> createState() => _TransformationsScreenState();
}

class _TransformationsScreenState extends State<TransformationsScreen> {
  Map<String, List<TransformRule>> _all = {};
  String _lang = 'en';
  bool _loading = true;

  static const List<({String code, String label})> _knownLangs = [
    (code: 'en', label: 'English'),
    (code: 'sv', label: 'Swedish'),
    (code: 'es', label: 'Spanish'),
    (code: 'fr', label: 'French'),
    (code: 'de', label: 'German'),
    (code: 'it', label: 'Italian'),
    (code: 'pt', label: 'Portuguese'),
    (code: 'nl', label: 'Dutch'),
    (code: 'da', label: 'Danish'),
    (code: 'nb', label: 'Norwegian'),
    (code: 'fi', label: 'Finnish'),
    (code: 'ru', label: 'Russian'),
    (code: 'hi', label: 'Hindi'),
    (code: 'ja', label: 'Japanese'),
    (code: 'zh', label: 'Chinese'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await TransformRuleStore.loadAll();
    if (!mounted) return;
    setState(() {
      _all = data;
      _loading = false;
    });
  }

  List<TransformRule> get _rules => _all[_lang] ?? const [];

  Future<void> _persist(List<TransformRule> rules) async {
    setState(() => _all = {..._all, _lang: rules});
    await TransformRuleStore.saveFor(_lang, rules);
  }

  Future<void> _addOrEdit({TransformRule? existing, int? index}) async {
    final result = await showDialog<TransformRule>(
      context: context,
      builder: (_) => _RuleEditorDialog(initial: existing),
    );
    if (result == null || !mounted) return;
    final list = List<TransformRule>.of(_rules);
    if (index == null) {
      list.add(result);
    } else {
      list[index] = result;
    }
    await _persist(list);
  }

  Future<void> _delete(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete rule?'),
        content: Text('Remove: ${_rules[index].pattern} → ${_rules[index].replacement}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final list = List<TransformRule>.of(_rules)..removeAt(index);
    await _persist(list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transformations'),
        actions: [
          IconButton(
            tooltip: 'Add rule',
            icon: const Icon(Icons.add),
            onPressed: _loading ? null : () => _addOrEdit(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.language, size: 18),
                      const SizedBox(width: 8),
                      Text('Language', style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _knownLangs.any((l) => l.code == _lang)
                              ? _lang
                              : _knownLangs.first.code,
                          items: _knownLangs
                              .map((l) => DropdownMenuItem(
                                    value: l.code,
                                    child: Text('${l.label} (${l.code})'),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _lang = v);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Rules run on pages whose HTML lang starts with "$_lang". '
                    'Original text is preserved so tagging identity stays intact.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _rules.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No rules yet. Tap + to add one.',
                              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _rules.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = _rules[i];
                            return ListTile(
                              leading: Icon(
                                r.type == 'substring'
                                    ? Icons.short_text
                                    : Icons.text_fields,
                                color: theme.colorScheme.primary,
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      r.pattern,
                                      style: const TextStyle(fontFamily: 'monospace'),
                                    ),
                                  ),
                                  const Icon(Icons.arrow_forward, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      r.replacement,
                                      style: const TextStyle(fontFamily: 'monospace'),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                r.type == 'substring'
                                    ? (r.wholeWord
                                        ? 'Whole-word match'
                                        : 'Partial substring (matches inside words)')
                                    : 'Word sequence (use [] for placeholder)',
                                style: theme.textTheme.bodySmall,
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(i),
                              ),
                              onTap: () => _addOrEdit(existing: r, index: i),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _RuleEditorDialog extends StatefulWidget {
  final TransformRule? initial;
  const _RuleEditorDialog({this.initial});

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  late String _type;
  late final TextEditingController _patternCtrl;
  late final TextEditingController _replCtrl;
  late bool _wholeWord;

  @override
  void initState() {
    super.initState();
    _type = widget.initial?.type ?? 'substring';
    _patternCtrl = TextEditingController(text: widget.initial?.pattern ?? '');
    _replCtrl = TextEditingController(text: widget.initial?.replacement ?? '');
    _wholeWord = widget.initial?.wholeWord ?? true;
  }

  @override
  void dispose() {
    _patternCtrl.dispose();
    _replCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add rule' : 'Edit rule'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'substring', label: Text('Substring')),
                ButtonSegment(value: 'sequence', label: Text('Sequence')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 12),
            Text(
              _type == 'substring'
                  ? 'Replace this substring inside any word (e.g. "af" → "av"). Case-sensitive.'
                  : 'Match a run of consecutive words. Use [] as a placeholder for "any word" — the matched word is copied into the same [] slot in the replacement.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _patternCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Pattern',
                hintText: _type == 'substring' ? 'af' : 'hade [] sett',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _replCtrl,
              decoration: InputDecoration(
                labelText: 'Replacement',
                hintText: _type == 'substring' ? 'av' : 'har [] sett',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            if (_type == 'substring') ...[
              const SizedBox(height: 8),
              // Whole-word matching is on by default so a rule like
              // "af → av" only rewrites the standalone token "af" and
              // leaves "afton" alone. Users who genuinely want in-word
              // substitutions (e.g. a spelling normalization) can flip
              // this off explicitly.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Whole word only'),
                subtitle: Text(
                  _wholeWord
                      ? 'Matches only when the pattern is a standalone token (e.g. "af").'
                      : 'Matches anywhere inside a word (e.g. "af" in "afton").',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
                value: _wholeWord,
                onChanged: (v) => setState(() => _wholeWord = v),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final p = _patternCtrl.text;
            final r = _replCtrl.text;
            if (p.isEmpty) return;
            Navigator.pop(
              context,
              TransformRule(
                type: _type,
                pattern: p,
                replacement: r,
                wholeWord: _type == 'substring' ? _wholeWord : true,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
