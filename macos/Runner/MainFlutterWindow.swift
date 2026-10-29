import Cocoa
import FlutterMacOS
import WebKit
import webview_flutter_wkwebview

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let recordingChannel = FlutterMethodChannel(
      name: "cupitor/perms",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    recordingChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      self.audioRecording.handle(call, result: result)
    }
    self.recordingChannel = recordingChannel

    // Dart passes a WebView's identifier (lib/mac_webview.dart) and we patch
    // the native WKWebView for what webview_flutter can't configure.
    let webviewChannel = FlutterMethodChannel(
      name: "cupitor/webview",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    webviewChannel.setMethodCallHandler { [weak self, weak flutterViewController] call, result in
      if call.method == "installFrameScript" {
        guard let args = call.arguments as? [String: Any],
          let script = args["script"] as? String, !script.isEmpty else {
          result(FlutterError(code: "invalid_script", message: "Missing frame script", details: nil))
          return
        }
        self?.frameScripts.setSource(script)
        result(nil)
        return
      }
      if call.method == "setWindowFullscreen" {
        self?.setPageFullscreen(call.arguments as? Bool ?? false)
        result(nil)
        return
      }
      guard call.method == "configureWebView" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let registry = flutterViewController,
        let id = (call.arguments as? NSNumber)?.int64Value,
        let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
          forIdentifier: id, withPluginRegistry: registry)
      else {
        result(false)
        return
      }
      // WKWebView refuses the HTML Fullscreen API unless this is on, so a
      // page's own fullscreen button (YouTube's, for one) does nothing.
      if #available(macOS 12.3, *) {
        webView.configuration.preferences.isElementFullscreenEnabled = true
      }
      JSPanelUIDelegate.install(on: webView)
      self?.frameScripts.configure(webView)
      result(true)
    }
    self.webviewChannel = webviewChannel

    let center = NotificationCenter.default
    center.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in
      self?.audioRecording.cancel()
    }
    for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
      center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.fullscreenTransitioning = true
      }
    }
    center.addObserver(
      forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in
      self?.fullscreenTransitioning = false
      self?.toggledByUs = false
      self?.convergeWindowFullscreen()
    }
    // When the user takes the window out of fullscreen (green button, Esc,
    // menu), page fullscreen follows it out.
    center.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.fullscreenTransitioning = false
      if self.toggledByUs {
        self.toggledByUs = false
        self.convergeWindowFullscreen()
      } else {
        self.windowFullscreenIsOurs = false
        self.pageWantsFullscreen = false
        self.webviewChannel?.invokeMethod("windowExitedFullscreen", arguments: nil)
      }
    }

    super.awakeFromNib()
  }

  private var webviewChannel: FlutterMethodChannel?
  private var recordingChannel: FlutterMethodChannel?
  private let audioRecording = NativeAudioRecording()
  private let frameScripts = FrameScriptInstaller()
  /// The window is fullscreen because a page asked, not because the user did.
  private var windowFullscreenIsOurs = false
  private var pageWantsFullscreen = false
  /// The window is animating in or out; a toggle now would be dropped.
  private var fullscreenTransitioning = false
  /// The transition under way was started here, not by the user.
  private var toggledByUs = false

  private func setPageFullscreen(_ on: Bool) {
    pageWantsFullscreen = on
    if !fullscreenTransitioning { convergeWindowFullscreen() }
  }

  /// Moves the window toward what the page wants. Re-run when a transition
  /// ends, so a request that arrived mid-animation still lands.
  private func convergeWindowFullscreen() {
    let isFullscreen = styleMask.contains(.fullScreen)
    if pageWantsFullscreen, !isFullscreen {
      windowFullscreenIsOurs = true
      toggledByUs = true
      toggleFullScreen(nil)
    } else if !pageWantsFullscreen, isFullscreen, windowFullscreenIsOurs {
      windowFullscreenIsOurs = false
      toggledByUs = true
      toggleFullScreen(nil)
    }
  }
}

/// Install in the page world at document start, including cross-origin
/// YouTube frames. Keep other user scripts (notably Flutter's JS channels)
/// when refreshing our remote source. Weak references avoid retaining dialogs.
final class FrameScriptInstaller {
  private let views = NSHashTable<WKWebView>.weakObjects()
  private var source: String?

  func configure(_ webView: WKWebView) {
    views.add(webView)
    if let source = source { install(source, replacing: nil, on: webView) }
  }

  func setSource(_ script: String) {
    guard script != source else { return }
    let old = source
    source = script
    for webView in views.allObjects { install(script, replacing: old, on: webView) }
  }

  private func install(_ script: String, replacing old: String?, on webView: WKWebView) {
    let content = webView.configuration.userContentController
    if content.userScripts.contains(where: { $0.source == script }) { return }
    if let old = old, content.userScripts.contains(where: { $0.source == old }) {
      let retained = content.userScripts.filter { $0.source != old }
      content.removeAllUserScripts()
      for item in retained { content.addUserScript(item) }
    }
    content.addUserScript(WKUserScript(source: script,
      injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }
}

/// Shows `alert()` / `confirm()` / `prompt()` as native alerts.
///
/// WKWebView shows nothing for these unless its UI delegate does, and the
/// plugin's delegate answers without asking: prompt() gets "" and confirm()
/// gets false. webview_flutter's Dart hook for prompt() can only return a
/// String, so Cancel could never reach the page as `null`. This sits in front
/// of the plugin's delegate, handles the three panels, and forwards every
/// other delegate call to it.
final class JSPanelUIDelegate: NSObject, WKUIDelegate {
  private static var key: UInt8 = 0
  private weak var inner: WKUIDelegate?

  private init(inner: WKUIDelegate?) {
    self.inner = inner
  }

  static func install(on webView: WKWebView) {
    if webView.uiDelegate is JSPanelUIDelegate { return }
    let wrapper = JSPanelUIDelegate(inner: webView.uiDelegate)
    // uiDelegate is weak; the web view keeps the wrapper alive.
    objc_setAssociatedObject(webView, &key, wrapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    webView.uiDelegate = wrapper
  }

  override func responds(to aSelector: Selector!) -> Bool {
    return super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    return inner?.responds(to: aSelector) == true ? inner : nil
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    present(alert, on: webView) { _ in completionHandler() }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    present(alert, on: webView) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = prompt
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = defaultText ?? ""
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    present(alert, on: webView) {
      completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
    }
  }

  private func present(
    _ alert: NSAlert, on webView: WKWebView,
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    if let window = webView.window {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }
}
