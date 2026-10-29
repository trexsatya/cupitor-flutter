import Cocoa
import FlutterMacOS
import XCTest
import WebKit
import AVFoundation
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
