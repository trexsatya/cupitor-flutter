import Cocoa
import FlutterMacOS
import XCTest
import WebKit
import AVFoundation
import Network
@testable import cupitor

@MainActor
class RunnerTests: XCTestCase {
  func testExistingAndFutureViewsGetDocumentStartScriptInEveryFrame() {
    let installer = FrameScriptInstaller()
    let first = WKWebView()
    installer.configure(first)
    installer.setSource("window.testFrameAgent = 1")
    let second = WKWebView()
    installer.configure(second)
    for view in [first, second] {
      let scripts = view.configuration.userContentController.userScripts
      XCTAssertEqual(scripts.count, 1)
      XCTAssertEqual(scripts[0].injectionTime, .atDocumentStart)
      XCTAssertFalse(scripts[0].isForMainFrameOnly)
    }
  }

  func testRefreshingSourcePreservesFlutterChannelScriptsAndDoesNotDuplicate() {
    let installer = FrameScriptInstaller()
    let view = WKWebView()
    let content = view.configuration.userContentController
    content.addUserScript(WKUserScript(source: "window.FlutterChannel = true",
      injectionTime: .atDocumentStart, forMainFrameOnly: false))
    installer.setSource("window.oldAgent = true")
    installer.configure(view)
    installer.setSource("window.newAgent = true")
    installer.configure(view)
    installer.setSource("window.newAgent = true")
    XCTAssertEqual(content.userScripts.map { $0.source },
      ["window.FlutterChannel = true", "window.newAgent = true"])
  }

  func testBrowserPopupKeepsTheOpenerAndItsDataStore() {
    let browser = BrowserWindows()
    let configuration = WKWebViewConfiguration()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.websiteDataStore = .nonPersistent()
    let opener = browser.openPopup(configuration: configuration)
    defer { opener.window?.close() }
    let navigation = AdBlockNavigation()
    let loaded = expectation(description: "opener loaded")
    navigation.finished = { loaded.fulfill() }
    opener.navigationDelegate = navigation
    opener.loadHTMLString("<title>Opener</title>", baseURL: nil)
    wait(for: [loaded], timeout: 10)

    let popup = expectation(description: "popup can talk to its opener")
    opener.evaluateJavaScript("""
      (() => {
        window.popup = window.open('about:blank');
        return window.popup !== null && window.popup.opener === window;
      })()
      """) { value, error in
      XCTAssertNil(error)
      XCTAssertEqual(value as? Bool, true)
      popup.fulfill()
    }
    wait(for: [popup], timeout: 10)
    let child = NSApp.windows.compactMap { window in
      window.contentView?.subviews.compactMap { $0 as? WKWebView }.first
    }.first { view in view !== opener && view.configuration.websiteDataStore === configuration.websiteDataStore }
    XCTAssertNotNil(child)
    defer { child?.window?.close() }
    XCTAssertEqual(opener.title, "Opener")
  }

  func testBrowserCaptureIsScopedToFilmot() {
    XCTAssertTrue(BrowserTab.isFilmot(URL(string: "https://filmot.com/search/word")))
    XCTAssertTrue(BrowserTab.isFilmot(URL(string: "https://beta.filmot.com/")))
    XCTAssertFalse(BrowserTab.isFilmot(URL(string: "https://notfilmot.com/")))
    XCTAssertFalse(BrowserTab.isFilmot(URL(string: "https://filmot.com.example.org/")))
    XCTAssertFalse(BrowserTab.canOpen(URL(string: "file:///tmp/test.html")!))
  }
}

/// A real loopback server lets WKWebView prove that a request was blocked,
/// rather than treating a DNS/network failure as successful ad suppression.
private final class AdBlockHTTPServer {
  let listener: NWListener
  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { connection in
      connection.start(queue: .main)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let body = request.contains("/blocked.js") ? "window.blockedLoaded = true" : "window.allowedLoaded = true"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
  deinit { listener.cancel() }
}

private final class AdBlockNavigation: NSObject, WKNavigationDelegate {
  var finished: (() -> Void)?
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
}

@MainActor
final class MacAdBlockerTests: XCTestCase {
  private func call(_ blocker: MacAdBlocker, _ method: String, _ arguments: Any? = nil) -> Any? {
    let done = expectation(description: method)
    var value: Any?
    blocker.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { value = $0; done.fulfill() }
    wait(for: [done], timeout: 15)
    XCTAssertFalse(value is FlutterError, "\(String(describing: value))")
    return value
  }

  func testHostRulesAreBoundedAndRejectURLsAndRegex() throws {
    XCTAssertEqual(MacAdBlocker.host("  ADS.Example.COM  "), "ads.example.com")
    for invalid in ["https://ads.example.com/path", "ads.*", "example.com/", "a..com", "-ads.example.com"] {
      XCTAssertNil(MacAdBlocker.host(invalid))
    }
    let data = MacAdBlocker.encodedRules(hosts: ["doubleclick.net"]).data(using: .utf8)!
    let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let trigger = try XCTUnwrap(rules[0]["trigger"] as? [String: String])
    let regex = try NSRegularExpression(pattern: XCTUnwrap(trigger["url-filter"]))
    for (url, blocked) in [
      ("https://doubleclick.net/ad", true), ("https://a.b.doubleclick.net:443/ad", true),
      ("https://example.com/?url=doubleclick.net/", false), ("https://doubleclick.net.example.com/ad", false),
      ("https://youtube.com/watch?v=abc", false), ("https://rr1.googlevideo.com/videoplayback", false),
    ] {
      XCTAssertEqual(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, blocked, url)
    }
  }

  func testRealWebViewsBlockHostsAndHonorDisableRemoveAndPersistence() throws {
    let suite = "cupitor-adblock-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let blocker = MacAdBlocker(defaults: defaults, identifier: suite)
    XCTAssertEqual(call(blocker, "addHost", ["host": "127.0.0.1"]) as? Bool, true)
    XCTAssertEqual(call(MacAdBlocker(defaults: defaults), "getCustomHosts") as? [String], ["127.0.0.1"])
    let server = try AdBlockHTTPServer()
    let listening = expectation(description: "loopback listening")
    server.listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
    server.listener.start(queue: .main)
    wait(for: [listening], timeout: 10)
    let port = try XCTUnwrap(server.listener.port).rawValue
    let first = WKWebView()
    let second = WKWebView()
    for view in [first, second] {
      let ready = expectation(description: "rules installed before first navigation")
      blocker.configure(view) { error in XCTAssertNil(error); ready.fulfill() }
      wait(for: [ready], timeout: 15)
    }
    let navigation = AdBlockNavigation()
    func check(_ view: WKWebView, blocked: Bool) {
      let loaded = expectation(description: "page and scripts loaded")
      navigation.finished = { loaded.fulfill() }
      view.navigationDelegate = navigation
      view.loadHTMLString("<script src='http://127.0.0.1:\(port)/blocked.js'></script><script src='http://localhost:\(port)/allowed.js'></script>", baseURL: URL(string: "http://localhost:\(port)/"))
      wait(for: [loaded], timeout: 15)
      let checked = expectation(description: "verify resource outcomes")
      view.evaluateJavaScript("[window.blockedLoaded === true, window.allowedLoaded === true]") { value, error in
        XCTAssertNil(error)
        XCTAssertEqual(value as? [Bool], [!blocked, true], "ordinary resources must still load")
        checked.fulfill()
      }
      wait(for: [checked], timeout: 10)
    }
    check(first, blocked: true)
    check(second, blocked: true) // future dialogs receive the same rules
    call(blocker, "setEnabled", ["enabled": false])
    check(first, blocked: false)
    call(blocker, "setEnabled", ["enabled": true])
    check(second, blocked: true)
    XCTAssertEqual(call(blocker, "removeHost", ["host": "127.0.0.1"]) as? Bool, true)
    check(first, blocked: false)
    XCTAssertEqual(call(MacAdBlocker(defaults: defaults), "getCustomHosts") as? [String], [])
    server.listener.cancel()
  }
}

private final class StubRecordingDevice: RecordingDevice {
  let url: URL
  var prepares = true
  var records = true
  var stops = 0
  var onStop: (() -> Void)?
  init(_ url: URL) { self.url = url }
  func prepareToRecord() -> Bool {
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    return prepares
  }
  func record() -> Bool { records }
  func stop() { stops += 1; onStop?() }
}

final class NativeAudioRecordingTests: XCTestCase {
  private var root: URL!
  private var stem: String { root.appendingPathComponent("manual_audio/clip-123").path }
  private var output: URL { URL(fileURLWithPath: stem + ".m4a") }

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func call(_ bridge: NativeAudioRecording, _ method: String, _ arguments: Any? = nil) -> Any? {
    var value: Any?
    bridge.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { value = $0 }
    return value
  }

  func testStartStopReturnsPlayableM4AAndKeepsItForTheCard() throws {
    let bridge = NativeAudioRecording(permission: { $0(true) }, factory: { url, settings in
      XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
      let device = StubRecordingDevice(url)
      device.onStop = {
        do {
          // Exercise the real AAC writer and reader without opening a CI mic.
          try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            buffer.frameLength = 4096
            for channel in 0..<Int(file.processingFormat.channelCount) {
              buffer.floatChannelData![channel].initialize(repeating: 0, count: 4096)
            }
            try file.write(from: buffer)
          }
        } catch { XCTFail("M4A encoding failed: \(error)") }
      }
      return device
    })
    XCTAssertEqual(call(bridge, "startNativeRecording", ["pathStem": stem]) as? String, output.path)
    XCTAssertEqual(call(bridge, "stopNativeRecording") as? String, output.path)
    XCTAssertGreaterThan(try AVAudioFile(forReading: output).length, 0)
    call(bridge, "cancelNativeRecording")
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testDeniedPermissionDoesNotCreateAClip() {
    let bridge = NativeAudioRecording(permission: { $0(false) }, factory: { _, _ in
      XCTFail("Denied permission must not reach the recorder")
      throw NSError(domain: "unexpected", code: 1)
    })
    let error = call(bridge, "startNativeRecording", ["pathStem": stem]) as? FlutterError
    XCTAssertEqual(error?.code, "PERMISSION")
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testCancelWhilePermissionIsPendingRepliesOnceAndNeverStartsLater() {
    var grant: ((Bool) -> Void)?
    var replies: [Any?] = []
    var factories = 0
    let bridge = NativeAudioRecording(permission: { grant = $0 }, factory: { url, _ in
      factories += 1; return StubRecordingDevice(url)
    })
    bridge.handle(FlutterMethodCall(methodName: "startNativeRecording", arguments: ["pathStem": stem])) {
      replies.append($0)
    }
    call(bridge, "cancelNativeRecording")
    XCTAssertEqual((replies.first! as? FlutterError)?.code, "CANCELLED")
    grant?(true)
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(factories, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testPendingAndActiveRecordersRejectAnotherStartAndStopCancelsPending() {
    var grants: [(Bool) -> Void] = []
    let bridge = NativeAudioRecording(permission: { grants.append($0) }, factory: { url, _ in
      StubRecordingDevice(url)
    }, hasAudio: { _ in true })
    call(bridge, "startNativeRecording", ["pathStem": stem])
    XCTAssertEqual((call(bridge, "startNativeRecording", ["pathStem": stem]) as? FlutterError)?.code, "BUSY")
    XCTAssertNil(call(bridge, "stopNativeRecording"))
    call(bridge, "startNativeRecording", ["pathStem": stem])
    grants[0](true) // The stopped request cannot complete the new one.
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    grants[1](true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    XCTAssertEqual((call(bridge, "startNativeRecording", ["pathStem": stem]) as? FlutterError)?.code, "BUSY")
    call(bridge, "cancelNativeRecording")
  }

  func testCancelActiveRecordingStopsAndDeletesThePartialFile() {
    var device: StubRecordingDevice!
    let bridge = NativeAudioRecording(permission: { $0(true) }, factory: { url, _ in
      device = StubRecordingDevice(url); return device
    })
    call(bridge, "startNativeRecording", ["pathStem": stem])
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    call(bridge, "cancelNativeRecording")
    XCTAssertEqual(device.stops, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testPrepareOrRecordFailureCleansUpAndAllowsRetry() {
    for prepareFailure in [true, false] {
      var fails = true
      let bridge = NativeAudioRecording(permission: { $0(true) }, factory: { url, _ in
        let device = StubRecordingDevice(url)
        device.prepares = !(fails && prepareFailure)
        device.records = !(fails && !prepareFailure)
        return device
      })
      XCTAssertEqual((call(bridge, "startNativeRecording", ["pathStem": stem]) as? FlutterError)?.code, "START_FAILED")
      XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
      fails = false
      XCTAssertEqual(call(bridge, "startNativeRecording", ["pathStem": stem]) as? String, output.path)
      call(bridge, "cancelNativeRecording")
    }
  }

  func testFactoryFailureCleansAnyPartialFile() {
    let bridge = NativeAudioRecording(permission: { $0(true) }, factory: { url, _ in
      _ = FileManager.default.createFile(atPath: url.path, contents: Data([1]))
      throw NSError(domain: "test", code: 1)
    })
    XCTAssertEqual((call(bridge, "startNativeRecording", ["pathStem": stem]) as? FlutterError)?.code, "START_FAILED")
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }

  func testExistingRecordingIsNeverOverwritten() throws {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: output)
    let bridge = NativeAudioRecording(permission: { $0(true) })
    XCTAssertEqual((call(bridge, "startNativeRecording", ["pathStem": stem]) as? FlutterError)?.code, "FILE_EXISTS")
    XCTAssertEqual(try Data(contentsOf: output), Data([1, 2, 3]))
  }

  func testAnEmptyOrInvalidRecordingIsDiscardedOnStop() {
    let bridge = NativeAudioRecording(permission: { $0(true) }, factory: { url, _ in StubRecordingDevice(url) })
    call(bridge, "startNativeRecording", ["pathStem": stem])
    XCTAssertNil(call(bridge, "stopNativeRecording"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertNil(call(bridge, "stopNativeRecording"))
  }

  func testInvalidPathIsRejectedBeforeRequestingMicrophonePermission() {
    let bridge = NativeAudioRecording(permission: { _ in XCTFail("Invalid path requested permission") })
    for path in ["relative", root.appendingPathComponent("elsewhere/clip").path,
                 root.appendingPathComponent("manual_audio/../clip").path] {
      XCTAssertEqual((call(bridge, "startNativeRecording", ["pathStem": path]) as? FlutterError)?.code, "BAD_PATH")
    }
  }
}
