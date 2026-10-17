import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Installs dialog1's controls API before its first navigation. A page script
/// alone cannot inject CSS into a cross-origin YouTube iframe.
Future<bool> installYouTubeControls(WebViewController controller) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  final platform = controller.platform;
  if (platform is! AndroidWebViewController) return false;
  try {
    final script = await rootBundle.loadString('assets/js/youtube_controls.js');
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
