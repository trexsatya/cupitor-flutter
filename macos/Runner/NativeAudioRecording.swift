import AVFoundation
import FlutterMacOS
import Foundation

protocol RecordingDevice: AnyObject {
  func prepareToRecord() -> Bool
  func record() -> Bool
  func stop()
}

extension AVAudioRecorder: RecordingDevice {}

/// The same cupitor/perms recording contract used on Android. Channel calls
/// and permission completions run on the main queue, so start/stop/cancel are
/// serialized even while the system permission sheet is open.
final class NativeAudioRecording {
  typealias Permission = (@escaping (Bool) -> Void) -> Void
  typealias Factory = (URL, [String: Any]) throws -> RecordingDevice

  private let permission: Permission
  private let factory: Factory
  private let hasAudio: (URL) -> Bool
  private var pending: (id: UUID, reply: FlutterResult)?
  private var active: (device: RecordingDevice, url: URL)?

  init(
    permission: @escaping Permission = NativeAudioRecording.requestMicrophone,
    factory: @escaping Factory = { try AVAudioRecorder(url: $0, settings: $1) },
    hasAudio: @escaping (URL) -> Bool = { url in
      guard let file = try? AVAudioFile(forReading: url) else { return false }
      return file.length > 0
    }
  ) {
    self.permission = permission
    self.factory = factory
    self.hasAudio = hasAudio
  }

  static func requestMicrophone(_ reply: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: reply(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { allowed in
        DispatchQueue.main.async { reply(allowed) }
      }
    default: reply(false)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestMicrophone": permission { result($0) }
    case "startNativeRecording":
      let args = call.arguments as? [String: Any]
      start(args?["pathStem"] as? String, reply: result)
    case "stopNativeRecording":
      cancelPending()
      guard let recording = active else { result(nil); return }
      active = nil
      recording.device.stop()
      if hasAudio(recording.url) {
        result(recording.url.path)
      } else {
        try? FileManager.default.removeItem(at: recording.url)
        result(nil)
      }
    case "cancelNativeRecording":
      cancel()
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ pathStem: String?, reply: @escaping FlutterResult) {
    guard active == nil, pending == nil else {
      reply(FlutterError(code: "BUSY", message: "Another recording is in progress.", details: nil))
      return
    }
    guard let stem = pathStem, stem.hasPrefix("/") else {
      reply(FlutterError(code: "BAD_PATH", message: "Missing recording path.", details: nil))
      return
    }
    let source = URL(fileURLWithPath: stem).standardizedFileURL
    guard source.path == stem,
      source.deletingLastPathComponent().lastPathComponent == "manual_audio",
      source.lastPathComponent.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
      reply(FlutterError(code: "BAD_PATH", message: "Invalid recording path.", details: nil))
      return
    }
    let url = source.appendingPathExtension("m4a")
    let id = UUID()
    pending = (id, reply)
    permission { [weak self] allowed in
      guard let self = self, let request = self.pending, request.id == id else { return }
      self.pending = nil
      guard allowed else {
        request.reply(FlutterError(code: "PERMISSION", message:
          "Allow microphone access for Cupitor in System Settings → Privacy & Security → Microphone.", details: nil))
        return
      }
      // AVAudioRecorder overwrites its destination when preparing. A new
      // recorder must never replace a clip that is already saved.
      guard !FileManager.default.fileExists(atPath: url.path) else {
        request.reply(FlutterError(code: "FILE_EXISTS", message: "This recording already exists.", details: nil))
        return
      }
      var device: RecordingDevice?
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        let recorder = try self.factory(url, [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 44100.0,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 64000,
          AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        device = recorder
        guard recorder.prepareToRecord(), recorder.record() else {
          throw NSError(domain: "CupitorRecording", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The microphone could not start recording."])
        }
        self.active = (recorder, url)
        request.reply(url.path)
      } catch {
        device?.stop()
        try? FileManager.default.removeItem(at: url)
        request.reply(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
      }
    }
  }

  private func cancelPending() {
    guard let request = pending else { return }
    pending = nil
    request.reply(FlutterError(code: "CANCELLED", message: "Recording was cancelled.", details: nil))
  }

  func cancel() {
    cancelPending()
    guard let recording = active else { return }
    active = nil
    recording.device.stop()
    try? FileManager.default.removeItem(at: recording.url)
  }

  deinit {
    if let recording = active {
      recording.device.stop()
      try? FileManager.default.removeItem(at: recording.url)
    }
  }
}
