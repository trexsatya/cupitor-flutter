/// Title and channel for a captured subtitle.
///
/// The webapp files a capture as `channel || title || id`, falling back to
/// the title when there is no channel. Some capture paths know neither well:
/// the yt-dlp path has no channel, a Filmot page's channel link may not be
/// found, and the text scraped for a Filmot title runs on into the page's
/// link icon, view and like counts and upload date
/// ("GÅR PÅ CIRKUS!↗ 359.8K 8.5K 18 Jun 2024"). YouTube's oEmbed endpoint
/// answers both for any public video, without a key.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

// Filmot's badges after a title: views, likes, upload date ("359.8K 8.5K 18 Jun 2024").
final _badgeTail = RegExp(r'(\s+[\d.,]+[KMB]?){1,2}\s+\d{1,2} [A-Z][a-z]{2} \d{4}$');

/// The scraped title without what follows Filmot's "↗" link icon, or its
/// trailing view / like / date badges.
String cleanCapturedTitle(String raw) {
  final cut = raw.indexOf('↗');
  final t = (cut >= 0 ? raw.substring(0, cut) : raw).trim();
  return t.replaceFirst(_badgeTail, '').trim();
}

/// `(title, channel)` from YouTube oEmbed, or null when it cannot say
/// (private or deleted video, no network, timeout).
Future<({String title, String channel})?> fetchYouTubeOembed(String videoId,
    {http.Client? client, Duration timeout = const Duration(seconds: 5)}) async {
  final url = Uri.parse('https://www.youtube.com/oembed?format=json&url='
      '${Uri.encodeComponent('https://www.youtube.com/watch?v=$videoId')}');
  try {
    final r = await (client != null ? client.get(url) : http.get(url)).timeout(timeout);
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (
      title: (j['title'] ?? '').toString().trim(),
      channel: (j['author_name'] ?? '').toString().trim(),
    );
  } catch (_) {
    return null;
  }
}

/// [payload] with `channel` and a clean `videoTitle` filled in. A channel the
/// payload already has is kept; [lookup] is asked only when it has none.
Future<Map<String, dynamic>> withCaptureMeta(
  Map<String, dynamic> payload,
  Future<({String title, String channel})?> Function(String videoId) lookup,
) async {
  final out = Map<String, dynamic>.from(payload);
  final scraped = cleanCapturedTitle((out['videoTitle'] ?? '').toString());
  out['videoTitle'] = scraped;
  final id = (out['videoId'] ?? '').toString();
  if (id.isEmpty || (out['channel'] ?? '').toString().trim().isNotEmpty) return out;
  final meta = await lookup(id);
  if (meta == null) return out;
  if (meta.channel.isNotEmpty) out['channel'] = meta.channel;
  if (meta.title.isNotEmpty) out['videoTitle'] = meta.title;
  return out;
}
