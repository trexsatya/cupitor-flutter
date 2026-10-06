import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const _channel = MethodChannel('cupitor/webview');

/// macOS: native WKWebView setup webview_flutter has no API for — the HTML
/// Fullscreen API, and native alert/confirm/prompt panels
/// (macos/Runner/MainFlutterWindow.swift). Call once per WebViewController,
/// right after creating it (`WebViewController()..configureForMac()`); a no-op
/// on other platforms.
extension MacWebView on WebViewController {
  void configureForMac() {
    if (!Platform.isMacOS) return;
    final platform = this.platform;
    if (platform is! WebKitWebViewController) return;
    _channel
        .invokeMethod<bool>('configureWebView', platform.webViewIdentifier)
        .then((ok) {
          if (ok != true) debugPrint('configureMacWebView: WebView not found');
        })
        .catchError((Object e) {
          debugPrint('configureMacWebView failed: $e');
        });
  }
}

/// macOS: put the app window into (or out of) native fullscreen. Leaving only
/// undoes a fullscreen this call entered, never one the user chose.
Future<void> setMacWindowFullscreen(bool on) async {
  if (!Platform.isMacOS) return;
  try {
    await _channel.invokeMethod<void>('setWindowFullscreen', on);
  } catch (e) {
    debugPrint('setMacWindowFullscreen failed: $e');
  }
}

/// macOS: [onExit] runs when the window leaves native fullscreen by any route
/// (green button, Esc, menu), so page fullscreen can follow it out.
void onMacWindowExitedFullscreen(VoidCallback onExit) {
  if (!Platform.isMacOS) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'windowExitedFullscreen') onExit();
  });
}

/// macOS: page fullscreen inside the WebView instead of WebKit's own.
///
/// WebKit's fullscreen lifts the element into a separate native window, so
/// Flutter widgets over the WebView (the floating chips) are left behind.
/// This replaces the Fullscreen API in the page: the requested element is
/// pinned over the whole viewport, and FullscreenChannel gets 'mac-enter' /
/// 'mac-exit' so the app can hide its chrome and fullscreen the window. The
/// fullscreen state, getters and events are faked to match what pages read.
/// `window.__cupExitFakeFs()` leaves it from the app side. Only the main frame
/// is patched; a cross-origin iframe player still uses WebKit's fullscreen.
/// Idempotent — safe to re-run on every page-finished.
const String kInPageFullscreenJs = r'''
(function() {
  if (window.__cupFakeFs) return;
  window.__cupFakeFs = true;
  var cur = null, watch = null;
  function style() {
    if (document.getElementById('__cupFsStyle')) return;
    var s = document.createElement('style');
    s.id = '__cupFsStyle';
    s.textContent = '.__cup-fs{position:fixed!important;inset:0!important;' +
      'width:100%!important;height:100%!important;max-width:none!important;' +
      'max-height:none!important;margin:0!important;transform:none!important;' +
      'z-index:2147483647!important;background:#000!important}';
    (document.head || document.documentElement).appendChild(s);
  }
  function fire(el) {
    ['fullscreenchange', 'webkitfullscreenchange'].forEach(function(t) {
      el.dispatchEvent(new Event(t, {bubbles: true}));
    });
    window.dispatchEvent(new Event('resize'));
  }
  function post(m) { try { FullscreenChannel.postMessage(m); } catch (e) {} }
  function enter(el) {
    if (cur === el) return Promise.resolve();
    if (cur) cur.classList.remove('__cup-fs');
    style();
    cur = el;
    el.classList.add('__cup-fs');
    // A site that swaps the element out (an SPA route change) without
    // exiting would otherwise leave the app in fullscreen with nothing in it.
    if (!watch) watch = setInterval(function() {
      if (cur && !cur.isConnected) leave();
    }, 500);
    post('mac-enter');
    fire(el);
    return Promise.resolve();
  }
  function leave() {
    if (!cur) return Promise.resolve();
    var el = cur;
    cur = null;
    clearInterval(watch);
    watch = null;
    el.classList.remove('__cup-fs');
    post('mac-exit');
    fire(el.isConnected ? el : document);
    return Promise.resolve();
  }
  window.__cupExitFakeFs = leave;
  var E = Element.prototype, D = Document.prototype;
  E.requestFullscreen = function() { return enter(this); };
  E.webkitRequestFullscreen = E.webkitRequestFullScreen = function() { enter(this); };
  if (window.HTMLVideoElement) {
    HTMLVideoElement.prototype.webkitEnterFullscreen =
      HTMLVideoElement.prototype.webkitEnterFullScreen = function() { enter(this); };
  }
  D.exitFullscreen = function() { return leave(); };
  D.webkitExitFullscreen = D.webkitCancelFullScreen = function() { leave(); };
  function getter(name, fn) {
    try { Object.defineProperty(D, name, {configurable: true, get: fn}); } catch (e) {}
  }
  ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']
    .forEach(function(n) { getter(n, function() { return cur; }); });
  ['fullscreenEnabled', 'webkitFullscreenEnabled']
    .forEach(function(n) { getter(n, function() { return true; }); });
  ['fullscreen', 'webkitIsFullScreen']
    .forEach(function(n) { getter(n, function() { return !!cur; }); });
  document.addEventListener('keydown', function(e) {
    if (cur && e.key === 'Escape') { e.preventDefault(); leave(); }
  }, true);
})();
''';
