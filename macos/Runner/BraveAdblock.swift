import Cocoa
import WebKit

/// The macOS half of the shared Brave engine: WebKit's public rule-list API
/// handles subresources, and engine-selected scriptlets run at document start.
final class BraveMacAdblock {
  static let shared = BraveMacAdblock()
  private(set) var ready = false
  private(set) var enabled = true
  private var source: String?
  private var rawSource: String?
  private var rules: WKContentRuleList?
  private let views = NSHashTable<WKWebView>.weakObjects()
  private let worker = DispatchQueue(label: "org.satya.cupitor.brave")
  private let store = WKContentRuleListStore.default()!

  static func nativeQuery(_ input: String) -> [String: Any] {
    guard let pointer = input.withCString({ cupitor_adblock_query($0) }) else { return [:] }
    defer { cupitor_adblock_free(pointer) }
    return (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any] ?? [:]
  }

  func initialize(directory: String, completion: @escaping ([String: Any]) -> Void) {
    worker.async {
      let pointer = directory.withCString { path in
        "macos".withCString { platform in cupitor_adblock_initialize(path, platform) }
      }
      guard let pointer else {
        DispatchQueue.main.async { completion(["ready": false, "error": "Brave initialization failed"]) }
        return
      }
      let status = (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any] ?? [:]
      cupitor_adblock_free(pointer)
      guard status["ready"] as? Bool == true,
        let script = Self.nativeQuery("{\"op\":\"script\"}")["script"] as? String,
        let list = Self.nativeQuery("{\"op\":\"webkit\"}")["rules"] as? [[String: Any]],
        let data = try? JSONSerialization.data(withJSONObject: list),
        let json = String(data: data, encoding: .utf8) else {
        let failure: [String: Any] = status["ready"] as? Bool == true || status.isEmpty
          ? ["ready": false, "error": "Invalid Brave data"] : status
        DispatchQueue.main.async { completion(failure) }
        return
      }
      let identifier = "cupitor-brave-\(status["version"] ?? 0)"
      DispatchQueue.main.async {
        func installed(_ compiled: WKContentRuleList?, _ error: Error?) {
          guard let compiled else {
            completion(["ready": false, "error": error?.localizedDescription ?? "WebKit rule compilation failed"])
            return
          }
          let oldRules = self.rules, oldSource = self.source
          self.rules = compiled
          self.rawSource = script
          self.source = self.documentSource(script)
          self.ready = true
          for view in self.views.allObjects {
            if let oldRules { view.configuration.userContentController.remove(oldRules) }
            self.apply(to: view, replacing: oldSource)
          }
          completion(status)
        }
        self.store.lookUpContentRuleList(forIdentifier: identifier) { existing, _ in
          if let existing { installed(existing, nil) }
          else { self.store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json, completionHandler: installed) }
        }
      }
    }
  }

  func configure(_ view: WKWebView) {
    views.add(view)
    apply(to: view, replacing: nil)
  }

  private func apply(to view: WKWebView, replacing old: String?) {
    let content = view.configuration.userContentController
    if let rules {
      content.remove(rules)
      if enabled { content.add(rules) }
    }
    guard let source, !content.userScripts.contains(where: { $0.source == source }) else { return }
    let retained = content.userScripts.filter { $0.source != old }
    content.removeAllUserScripts()
    // Before Cupitor's fallback frame agent, so it can stand down its old
    // JSON hooks while retaining its ad-state and Skip safety nets.
    content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    for item in retained { content.addUserScript(item) }
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    let old = source
    if let rawSource { source = documentSource(rawSource) }
    for view in views.allObjects {
      apply(to: view, replacing: old)
    }
  }

  private func documentSource(_ script: String) -> String {
    // WKWebView may suppress prompt transport on an unattached/background
    // view. Precompiled YouTube scriptlets and selectors still run before the
    // first site script; dynamic page queries become available when attached.
    return "window.__cupitorBraveBootstrap={ready:true,enabled:\(enabled ? "true" : "false")};\n" + script
  }

  /// Synchronous prompt transport allows document-start code to select page
  /// resources before website scripts run. This never opens a native dialog.
  func pageQuery(_ message: String?, frame: WKFrameInfo) -> String {
    guard ready, let message, message.utf8.count <= 65536,
      let data = message.data(using: .utf8),
      let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let operation = input["op"] as? String, ["status", "page", "selectors", "network"].contains(operation),
      let address = input["url"] as? String, let url = URL(string: address),
      ["https", "http"].contains(url.scheme ?? ""),
      url.host?.lowercased() == frame.securityOrigin.host.lowercased(),
      url.scheme == frame.securityOrigin.protocol else { return "{\"ready\":false,\"enabled\":false}" }
    if !enabled && operation != "status" { return "{}" }
    var response = Self.nativeQuery(message)
    response["enabled"] = enabled
    guard let encoded = try? JSONSerialization.data(withJSONObject: response) else { return "{}" }
    return String(data: encoded, encoding: .utf8) ?? "{}"
  }
}
