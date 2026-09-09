/// Selection algebra and delete bookkeeping for the voice-recordings browser.
///
/// Kept free of Flutter so the rules can be tested directly. Recordings are
/// identified by file path: the browser rebuilds its row objects on every
/// reload, so object identity would not survive one.
library;

/// Adds [id] if absent, removes it if present.
Set<String> toggleSelection(Set<String> current, String id) {
  final next = Set<String>.of(current);
  if (!next.remove(id)) next.add(id);
  return next;
}

/// The select-all / select-none toggle.
///
/// Selects everything unless everything is already selected, in which case it
/// clears. Clearing empties the set, which ends selection mode — the caller
/// derives the mode from emptiness rather than tracking it separately.
Set<String> selectAllOrNone(Set<String> current, List<String> all) {
  if (all.isEmpty) return <String>{};
  final everything = Set<String>.of(all);
  if (current.length >= everything.length &&
      everything.every(current.contains)) {
    return <String>{};
  }
  return everything;
}

/// Drops ids that are no longer on disk, so a deleted or vanished recording
/// cannot linger as a phantom selection across a reload.
Set<String> pruneSelection(Set<String> current, List<String> stillPresent) {
  if (current.isEmpty) return <String>{};
  final present = Set<String>.of(stillPresent);
  return current.where(present.contains).toSet();
}

/// Outcome of a bulk delete.
class DeleteTally {
  final int removed;
  final int failed;

  const DeleteTally({required this.removed, required this.failed});

  bool get allSucceeded => failed == 0;

  /// Snackbar text. Mentions failures only when there are some — a clean run
  /// should not make the user parse a zero.
  String get message => failed == 0
      ? 'Removed $removed recording(s)'
      : 'Removed $removed — $failed failed';
}

/// Body of the delete confirmation.
///
/// [formatted] is the human-readable total size, so this stays free of the
/// byte formatter and the widget layer.
String deleteConfirmBody(int count, String formatted) {
  final subject = count == 1 ? 'this clip' : 'all $count clips';
  return 'Remove $subject ($formatted). Manual cards that reference '
      '${count == 1 ? 'it' : 'any of these'} will lose their audio.';
}
