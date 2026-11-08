import Cocoa
import FlutterMacOS
import WebKit
import webview_flutter_wkwebview

class MainFlutterWindow: NSWindow {
  // An embedded WKContentView may be the first responder rather than its
  // enclosing WKWebView. Walk the view ancestry to find the actual owner.
  // Do not consume Cmd+F from Flutter-only screens such as the EPUB reader.
  private var webViewHasFocus: Bool {
    var view = firstResponder as? NSView
    while let current = view {
      if current is WKWebView { return true }
      view = current.superview
    }
    return false
  }

  // Native WKWebView text input handles key equivalents before Flutter sees
  // them. Catch Cmd+F only when a page has focus; Flutter handles its own keys.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if webViewHasFocus && event.type == .keyDown && !event.isARepeat &&
        modifiers == .command &&
        event.charactersIgnoringModifiers?.lowercased() == "f" {
      webviewChannel?.invokeMethod("findShortcut", arguments: nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

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

    let adBlockChannel = FlutterMethodChannel(
      name: "cupitor/adblock",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    adBlockChannel.setMethodCallHandler { [weak self] call, result in
      self?.adBlocker.handle(call, result: result)
    }
    self.adBlockChannel = adBlockChannel

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
      self?.adBlocker.configure(webView) { error in
        if let error = error {
          result(FlutterError(code: "adblock_rules", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }
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
  private var adBlockChannel: FlutterMethodChannel?
  private let adBlocker = MacAdBlocker()
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

/// WKWebView does not use Android's shouldInterceptRequest client. Install
/// compiled WebKit rules before navigation, on every browser and dialog view.
/// Own only our list; Flutter's user scripts and other rule lists stay intact.
final class MacAdBlocker {
  static let builtInHosts: Set<String> = [
    "googlesyndication.com", "doubleclick.net", "googleadservices.com",
    "adservice.google.com", "adservice.google.co.uk", "adnxs.com",
    "advertising.com", "amazon-adsystem.com", "ads.yahoo.com", "taboola.com",
    "outbrain.com", "moatads.com", "adsafeprotected.com", "scorecardresearch.com",
    "static.ads-twitter.com", "ads.twitter.com", "ads.linkedin.com",
    "googletagservices.com", "criteo.com", "rubiconproject.com", "openx.net",
    "pubmatic.com", "contextweb.com", "bidswitch.net", "casalemedia.com",
  ]
  private let views = NSHashTable<WKWebView>.weakObjects()
  private let defaults: UserDefaults
  private let store: WKContentRuleListStore
  private let identifier: String
  private var customHosts: Set<String>
  private var enabled = true
  private var rules: WKContentRuleList?
  private var compiling = false
  private var revision = 0
  private var ready: [(Error?) -> Void] = []
  private static let hostsKey = "cupitor.adblock.customHosts"

  init(defaults: UserDefaults = .standard, store: WKContentRuleListStore = .default(),
       identifier: String = "cupitor-ad-hosts") {
    self.defaults = defaults
    self.store = store
    self.identifier = identifier
    customHosts = Set((defaults.stringArray(forKey: Self.hostsKey) ?? []).compactMap(Self.host))
  }

  static func host(_ input: String) -> String? {
    let host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Accept a DNS hostname, never a URL/regex: a pasted path or metacharacter
    // must not turn a custom rule into a block on unrelated sites.
    guard host.utf8.count <= 253, host.contains("."),
      host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
          label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
      }) else { return nil }
    return host
  }

  static func encodedRules(hosts: Set<String>) -> String {
    let list: [[String: Any]] = hosts.sorted().map { host in
      // Anchor at the hostname boundary, including subdomains, without
      // matching good.example/?next=doubleclick.net or doubleclick.net.evil.
      ["trigger": ["url-filter": "^https?://([^/:]+\\.)?" +
        host.replacingOccurrences(of: ".", with: "\\.") + "(:[0-9]+)?/"],
       "action": ["type": "block"]]
    }
    return String(data: try! JSONSerialization.data(withJSONObject: list), encoding: .utf8)!
  }

  func configure(_ webView: WKWebView, completion: @escaping (Error?) -> Void) {
    views.add(webView)
    if rules != nil {
      apply(to: webView)
      completion(nil)
    } else {
      ready.append(completion)
      compile()
    }
  }

  private func apply(to view: WKWebView) {
    guard let rules = rules else { return }
    let content = view.configuration.userContentController
    content.remove(rules)
    if enabled { content.add(rules) }
  }

  private func compile() {
    guard !compiling else { return }
    compiling = true
    let current = revision
    let json = Self.encodedRules(hosts: Self.builtInHosts.union(customHosts))
    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
      [weak self] compiled, error in
      guard let self = self else { return }
      self.compiling = false
      // A host change during compilation must not install stale rules or
      // release a waiting first navigation with an incomplete host list.
      if self.revision != current { self.compile(); return }
      if let compiled = compiled {
        for view in self.views.allObjects {
          if let old = self.rules { view.configuration.userContentController.remove(old) }
        }
        self.rules = compiled
        for view in self.views.allObjects { self.apply(to: view) }
      }
      let callbacks = self.ready
      self.ready.removeAll()
      for callback in callbacks { callback(error) }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "getCustomHosts": result(customHosts.sorted())
    case "setEnabled":
      enabled = args["enabled"] as? Bool ?? true
      for view in views.allObjects { apply(to: view) }
      result(nil)
    case "addHost", "removeHost":
      guard let raw = args["host"] as? String, let host = Self.host(raw) else {
        result(FlutterError(code: "BAD_ARG", message: "Enter a hostname such as ads.example.com", details: nil))
        return
      }
      let changed: Bool
      if call.method == "addHost" {
        changed = !Self.builtInHosts.contains(host) && customHosts.insert(host).inserted
      } else {
        changed = customHosts.remove(host) != nil
      }
      guard changed else { result(false); return }
      defaults.set(customHosts.sorted(), forKey: Self.hostsKey)
      revision += 1
      ready.append { error in
        if let error = error {
          result(FlutterError(code: "adblock_rules", message: error.localizedDescription, details: nil))
        } else { result(true) }
      }
      compile()
    case "attach":
      if rules != nil { result(nil) } else {
        ready.append { error in
          if let error = error {
            result(FlutterError(code: "adblock_rules", message: error.localizedDescription, details: nil))
          } else { result(nil) }
        }
        compile()
      }
    default: result(FlutterMethodNotImplemented)
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
