import Cocoa
import FlutterMacOS
import XCTest
import WebKit
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
}
