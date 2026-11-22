import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'frame_script.dart';

/// Use the same exact-controller document-start registration for ad protection
/// and controls. The general frame-agent scanner only sees attached WebViews;
/// dialog1 can navigate and create its YouTube iframe before being attached.
Future<String> youtubeProtectionScript({
  String? frameScript,
  AssetBundle? bundle,
}) async {
  final assets = bundle ?? rootBundle;
  final sources = await Future.wait([
    assets.loadString('assets/js/frame_boot.js'),
    assets.loadString('assets/js/youtube_controls.js'),
  ]);
  return '${preferFrameScript(sources[0], frameScript)}\n${sources[1]}';
}

/// Installs dialog1's controls API before its first navigation. A page script
/// alone cannot inject CSS into a cross-origin YouTube iframe.
Future<bool> installYouTubeControls(
  WebViewController controller, {
  String? frameScript,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  final platform = controller.platform;
  if (platform is! AndroidWebViewController) return false;
  try {
    final script = await youtubeProtectionScript(frameScript: frameScript);
    return await const MethodChannel('cupitor/youtube_controls')
            .invokeMethod<bool>('install', {
          'webViewId': platform.webViewIdentifier,
          'script': script,
        }) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException catch (error) {
    debugPrint('[youtube-controls] ${error.message}');
    return false;
  } catch (error) {
    // A missing asset or failed install must not prevent dialog1 loading.
    debugPrint('[youtube-controls] $error');
    return false;
  }
}
