import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let window = mainFlutterWindow as? MainFlutterWindow else {
      super.application(application, open: urls)
      return
    }
    let remaining = urls.filter { !window.openBrowser($0) }
    if !remaining.isEmpty { super.application(application, open: remaining) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
