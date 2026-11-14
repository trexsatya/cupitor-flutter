import Cocoa
import WebKit

/// Owns browser windows and the single study action the browser exposes.
@MainActor
final class BrowserWindows {
  private var tabs: [ObjectIdentifier: BrowserTab] = [:]
  lazy var captureScript: String? = Bundle.main.url(forResource: "filmot_capture", withExtension: "js")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
  var onFilmotCapture: ((String) -> Void)?

  @discardableResult
  func open(_ url: URL, beside window: NSWindow? = nil) -> Bool {
    guard BrowserTab.canOpen(url) else { return false }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let tab = makeTab(configuration: configuration, popup: false)
    window?.addTabbedWindow(tab.window, ordered: .above)
    tab.window.makeKeyAndOrderFront(nil)
    tab.webView.load(URLRequest(url: url))
    return true
  }

  func openPopup(configuration: WKWebViewConfiguration) -> WKWebView {
    // WebKit supplies the configuration for an opener-related window and
    // loads its request. Reloading its URL ourselves loses that relationship.
    let tab = makeTab(configuration: configuration, popup: true)
    tab.window.makeKeyAndOrderFront(nil)
    return tab.webView
  }

  func didClose(_ tab: BrowserTab) {
    tabs.removeValue(forKey: ObjectIdentifier(tab))
  }

  private func makeTab(configuration: WKWebViewConfiguration, popup: Bool) -> BrowserTab {
    let tab = BrowserTab(browser: self, configuration: configuration, popup: popup)
    tabs[ObjectIdentifier(tab)] = tab
    return tab
  }
}

@MainActor
final class BrowserTab: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
  private weak var browser: BrowserWindows?
  let window: BrowserWindow
  let webView: WKWebView
  private let address = NSTextField()
  private let back = NSButton()
  private let forward = NSButton()
  private let reload = NSButton()
  private let capture = NSButton()
  private var observations: [NSKeyValueObservation] = []
  private var captureInProgress = false

  init(browser: BrowserWindows, configuration: WKWebViewConfiguration, popup: Bool) {
    self.browser = browser
    webView = WKWebView(frame: .zero, configuration: configuration)
    window = BrowserWindow(
      contentRect: NSRect(x: 0, y: 0, width: popup ? 720 : 1100, height: popup ? 640 : 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init()
    window.isReleasedWhenClosed = false
    window.title = "Cupitor Browser"
    window.minSize = NSSize(width: 550, height: 360)
    window.tabbingIdentifier = "CupitorBrowser"
    window.tabbingMode = popup ? .disallowed : .preferred
    window.delegate = self
    window.onBrowserShortcut = { [weak self] key in
      guard let self else { return false }
      switch key {
      case "l":
        self.window.makeFirstResponder(self.address)
        self.address.selectText(nil)
      case "r": self.reloadPage()
      case "t" where self.window.tabbingMode != .disallowed: self.newTab()
      case "w": self.window.performClose(nil)
      default: return false
      }
      return true
    }
    window.center()
    webView.navigationDelegate = self
    JSPanelUIDelegate.install(on: webView, forwardingTo: self)
    buildContent()
    observations = [
      webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.updateControls() },
      webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.updateControls() },
      webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateControls() },
      webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateControls() },
      webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.updateControls() },
    ]
    updateControls()
  }

  static func canOpen(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
    return (scheme == "http" || scheme == "https") && url.user == nil && url.password == nil
  }

  static func isFilmot(_ url: URL?) -> Bool {
    guard let url, canOpen(url), let host = url.host?.lowercased() else { return false }
    return host == "filmot.com" || host.hasSuffix(".filmot.com")
  }

  private func buildContent() {
    let root = NSView()
    window.contentView = root
    address.placeholderString = "Enter a web address"
    address.lineBreakMode = .byClipping
    address.target = self
    address.action = #selector(goToAddress)
    address.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let addTab = NSButton()
    configure(back, name: "Back", symbol: "chevron.left", action: #selector(goBack))
    configure(forward, name: "Forward", symbol: "chevron.right", action: #selector(goForward))
    configure(reload, name: "Reload", symbol: "arrow.clockwise", action: #selector(reloadPage))
    configure(addTab, name: "New tab", symbol: "plus", action: #selector(newTab))
    if window.tabbingMode == .disallowed { addTab.isHidden = true }
    capture.title = "Capture subtitles"
    capture.target = self
    capture.action = #selector(captureFilmot)

    let bar = NSStackView(views: [back, forward, reload, address, capture, addTab])
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 8
    bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    bar.translatesAutoresizingMaskIntoConstraints = false
    webView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bar)
    root.addSubview(webView)
    NSLayoutConstraint.activate([
      bar.topAnchor.constraint(equalTo: root.topAnchor),
      bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      address.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
      webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  private func configure(_ button: NSButton, name: String, symbol: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
    button.toolTip = name
    button.target = self
    button.action = action
  }

  private func updateControls() {
    let url = webView.url
    if address.currentEditor() == nil { address.stringValue = url?.absoluteString ?? "" }
    window.title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Cupitor Browser"
    back.isEnabled = webView.canGoBack
    forward.isEnabled = webView.canGoForward
    let loading = webView.isLoading
    reload.image = NSImage(
      systemSymbolName: loading ? "xmark" : "arrow.clockwise",
      accessibilityDescription: loading ? "Stop loading" : "Reload"
    )
    reload.toolTip = loading ? "Stop loading" : "Reload"
    capture.isHidden = !Self.isFilmot(url)
    capture.isEnabled = !loading && !captureInProgress
  }

  @objc private func goToAddress() {
    let input = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let complete = input.contains("://") ? input : "https://" + input
    guard let url = URL(string: complete), Self.canOpen(url) else {
      showMessage("Enter a valid HTTP or HTTPS address.")
      return
    }
    address.stringValue = url.absoluteString
    window.makeFirstResponder(webView)
    webView.load(URLRequest(url: url))
  }

  @objc private func goBack() { webView.goBack() }
  @objc private func goForward() { webView.goForward() }
  @objc private func reloadPage() {
    if webView.isLoading { webView.stopLoading() } else { webView.reload() }
  }
  @objc private func newTab() {
    browser?.open(URL(string: "https://www.google.com/")!, beside: window)
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard let url = navigationAction.request.url,
          Self.canOpen(url) || url.absoluteString == "about:blank" else { return nil }
    return browser?.openPopup(configuration: configuration)
  }

  func webViewDidClose(_ webView: WKWebView) { window.close() }

  func windowWillClose(_ notification: Notification) {
    webView.stopLoading()
    observations.removeAll()
    browser?.didClose(self)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    // Show the committed origin even if an address edit was in progress.
    address.stringValue = webView.url?.absoluteString ?? ""
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let topLevel = navigationAction.targetFrame?.isMainFrame ?? true
    let allowed = !topLevel || Self.canOpen(url) || url.absoluteString == "about:blank"
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    address.stringValue = webView.url?.absoluteString ?? ""
    showMessage(error.localizedDescription)
  }

  @objc private func captureFilmot() {
    guard let pageURL = webView.url, Self.isFilmot(pageURL),
          !webView.isLoading, !captureInProgress else { return }
    guard let script = browser?.captureScript else {
      showMessage("The Filmot capture script could not be loaded.")
      return
    }
    captureInProgress = true
    updateControls()
    webView.evaluateJavaScript(script) { [weak self] value, error in
      guard let self else { return }
      self.captureInProgress = false
      self.updateControls()
      guard self.webView.url == pageURL, !self.webView.isLoading else { return }
      guard error == nil, let payload = value as? String else {
        self.showMessage("Could not read the Filmot subtitles.")
        return
      }
      self.browser?.onFilmotCapture?(payload)
    }
  }

  private func showMessage(_ message: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.beginSheetModal(for: window)
  }
}

final class BrowserWindow: NSWindow {
  var onBrowserShortcut: ((String) -> Bool)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased(),
       onBrowserShortcut?(key) == true { return true }
    return super.performKeyEquivalent(with: event)
  }
}
