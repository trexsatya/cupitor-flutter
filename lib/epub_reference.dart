/// A link inside the EPUB archive, resolved without loading a custom URL.
class EpubReference {
  const EpubReference(this.chapterIndex, this.fragment);
  final int chapterIndex;
  final String fragment;
}

EpubReference? resolveEpubReference(
  String href, {
  required String currentHref,
  required List<String> chapterHrefs,
}) {
  final link = Uri.tryParse(href.trim());
  if (link == null) return null;
  final readerUrl = link.scheme == 'cupitor-epub' ||
      (link.scheme == 'https' && link.host == 'reader.cupitor.invalid');
  if (link.hasScheme && !readerUrl || link.hasAuthority && !readerUrl) return null;
  final base = Uri.parse('https://epub.invalid/').resolve(currentHref);
  var relative = link;
  if (readerUrl) {
    var path = link.path.replaceFirst(RegExp(r'^/chapter/\d+/'), '');
    path = path.replaceFirst(RegExp(r'^/'), '');
    relative = Uri(path: path, fragment: link.fragment);
  }
  final target = base.resolveUri(relative);
  final path = Uri.decodeComponent(target.path);
  final index = chapterHrefs.indexWhere((chapter) =>
      Uri.decodeComponent(Uri.parse('https://epub.invalid/').resolve(chapter).path) == path);
  if (index < 0) return null;
  return EpubReference(index, target.fragment);
}
