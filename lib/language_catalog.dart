import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class CupitorLanguage {
  const CupitorLanguage({
    required this.name,
    required this.code,
    required this.locale,
    required this.study,
  });

  final String name;
  final String code;
  final String locale;
  final bool study;

  String get label => name
      .split('-')
      .map((part) => part[0].toUpperCase() + part.substring(1))
      .join(' ');
}

class CupitorLanguageCatalog {
  CupitorLanguageCatalog._(this.languages);

  final List<CupitorLanguage> languages;

  List<CupitorLanguage> get studyLanguages =>
      languages.where((language) => language.study).toList(growable: false);

  CupitorLanguage? find(String value) {
    final key = value.trim().toLowerCase();
    for (final language in languages) {
      if ([
        language.code,
        language.name,
        language.locale.toLowerCase(),
      ].contains(key)) {
        return language;
      }
    }
    return null;
  }

  factory CupitorLanguageCatalog.parse(String text) {
    final data = jsonDecode(text);
    if (data is! Map || data['version'] != 1 || data['languages'] is! List) {
      throw const FormatException('Invalid Cupitor language catalog');
    }
    final languages = <CupitorLanguage>[];
    final codes = <String>{}, names = <String>{};
    final namePattern = RegExp(r'^[a-z][a-z-]*$');
    final codePattern = RegExp(r'^[a-z]{2,3}$');
    final localePattern = RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$');
    for (final item in data['languages']) {
      if (item is! Map ||
          item['name'] is! String ||
          item['code'] is! String ||
          item['locale'] is! String ||
          item['capabilities'] is! Map ||
          item['capabilities']['study'] is! bool) {
        throw const FormatException('Invalid Cupitor language');
      }
      final name = item['name'] as String, code = item['code'] as String;
      final locale = item['locale'] as String;
      if (!namePattern.hasMatch(name) ||
          name.split('-').any((part) => part.isEmpty) ||
          !codePattern.hasMatch(code) ||
          !localePattern.hasMatch(locale) ||
          !codes.add(code) ||
          !names.add(name)) {
        throw const FormatException('Invalid or duplicate Cupitor language');
      }
      languages.add(
        CupitorLanguage(
          name: name,
          code: code,
          locale: locale,
          study: item['capabilities']['study'] as bool,
        ),
      );
    }
    if (languages.isEmpty) {
      throw const FormatException('Empty Cupitor language catalog');
    }
    return CupitorLanguageCatalog._(List.unmodifiable(languages));
  }
}

class CupitorLanguageCatalogStore {
  CupitorLanguageCatalogStore(this.preferences, {this.client});

  static final endpoint = Uri.parse(
    'https://trexsatya.github.io/language/language-catalog.json',
  );
  static const cacheKey = 'cupitor:languageCatalog:v1';
  final SharedPreferences preferences;
  final http.Client? client;

  CupitorLanguageCatalog? readCached() {
    final text = preferences.getString(cacheKey);
    if (text == null) return null;
    try {
      return CupitorLanguageCatalog.parse(text);
    } catch (_) {
      return null;
    }
  }

  Future<CupitorLanguageCatalog> refresh() async {
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient
          .get(endpoint, headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw StateError(
          'Could not load Cupitor languages (${response.statusCode})',
        );
      }
      final text = utf8.decode(response.bodyBytes);
      final catalog = CupitorLanguageCatalog.parse(text);
      await preferences.setString(cacheKey, text);
      return catalog;
    } finally {
      if (client == null) requestClient.close();
    }
  }
}

/// Refresh on every opening; cached choices remain usable when offline.
/// Only languages supported by the study app belong in this selector.
class CupitorLanguagePicker extends StatefulWidget {
  const CupitorLanguagePicker({
    super.key,
    required this.selectedCode,
    required this.onSelected,
    required this.onCatalog,
    this.store,
  });

  final String selectedCode;
  final ValueChanged<CupitorLanguage> onSelected;
  final ValueChanged<CupitorLanguageCatalog> onCatalog;
  final CupitorLanguageCatalogStore? store;

  @override
  State<CupitorLanguagePicker> createState() => _CupitorLanguagePickerState();
}

class _CupitorLanguagePickerState extends State<CupitorLanguagePicker> {
  CupitorLanguageCatalog? _catalog;
  bool _loading = true, _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final store =
          widget.store ??
          CupitorLanguageCatalogStore(await SharedPreferences.getInstance());
      if (!mounted) return;
      final cached = store.readCached();
      if (cached != null) _adopt(cached);
      final catalog = await store.refresh();
      if (!mounted) return;
      _adopt(catalog);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _adopt(CupitorLanguageCatalog catalog) {
    setState(() => _catalog = catalog);
    widget.onCatalog(catalog);
  }

  @override
  Widget build(BuildContext context) {
    final choices = _catalog?.studyLanguages ?? const <CupitorLanguage>[];
    final selected = choices.where(
      (language) => language.code == widget.selectedCode,
    );
    return ListTile(
      leading: const Icon(Icons.language),
      title: const Text('Language'),
      subtitle: _failed
          ? Text(
              _catalog == null
                  ? 'Connect to load languages'
                  : 'Using saved languages',
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: selected.isEmpty ? null : widget.selectedCode,
            hint: Text(_loading ? 'Loading…' : 'Choose language'),
            items: choices
                .map(
                  (language) => DropdownMenuItem(
                    value: language.code,
                    child: Text(language.label),
                  ),
                )
                .toList(),
            onChanged: choices.isEmpty
                ? null
                : (code) {
                    if (code != null) {
                      widget.onSelected(
                        choices.firstWhere((language) => language.code == code),
                      );
                    }
                  },
            underline: const SizedBox(),
          ),
          if (_failed)
            IconButton(
              tooltip: 'Reload languages',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
    );
  }
}
