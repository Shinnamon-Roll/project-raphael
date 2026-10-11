import AVFoundation
import os

/// Why the microphone could not start, or stopped by itself.
public enum AudioSourceError: Error, Hashable, LocalizedError {
  /// macOS reports no input device, or one with no channels.
  case noInputDevice
  /// `AVAudioEngine` would not start; `code` is the system's error code, which is also logged.
  case cannotStart(code: Int)
  /// The input device changed, for example when AirPods connect, and the engine stopped.
  case deviceChanged

  // UI copy: the menu shows it as the reason.
  public var errorDescription: String? {
    switch self {
    case .noInputDevice: "No microphone found."
    case .cannotStart: "The microphone couldn't start."
    case .deviceChanged: "The microphone changed. Switch it on again."
    }
  }
}

/// The real microphone: one `AVAudioEngine` input tap.
///
/// Phase 1 step 1 grows this tap with conversion to 16 kHz mono, fan-out, the gate and the ring
/// buffer.
@MainActor
public final class AudioEngineSource: AudioSource {
  public var onStop: ((AudioSourceError) -> Void)?

  private let engine = AVAudioEngine()
  private var isCapturing = false
  private var configurationObserver: (any NSObjectProtocol)?
  private let log = Logger(subsystem: "com.shinnamon.uriel", category: "audio")

  public init() {}

  public func start() throws {
    guard !isCapturing else { return }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // installTap raises an Objective-C exception, which Swift cannot catch, on an empty format.
    guard format.channelCount > 0, format.sampleRate > 0 else {
      throw AudioSourceError.noInputDevice
    }
    // @Sendable keeps the block off the main actor: it runs on a real-time audio thread.
    // shortcut: drops every buffer, since nothing listens yet; Phase 1 step 1 converts and fans
    // them out. Move to the throwing installTap once the deployment target is macOS 27.
    input.installTap(onBus: 0, bufferSize: 8192, format: format) { @Sendable _, _ in }
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      let error = error as NSError
      log.error("AVAudioEngine did not start: \(error.domain, privacy: .public) \(error.code)")
      throw AudioSourceError.cannotStart(code: error.code)
    }
    isCapturing = true
    // The engine stops itself when the input device changes, then posts this notification.
    // shortcut: reports the stop instead of restarting; Phase 1 step 1 restarts the engine.
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      // Safe: the observer is queued on the main queue.
      MainActor.assumeIsolated { self?.engineConfigurationChanged() }
    }
  }

  public func stop() {
    guard isCapturing else { return }
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = nil
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    isCapturing = false
  }

  private func engineConfigurationChanged() {
    // A change that left the engine running needs nothing.
    guard isCapturing, !engine.isRunning else { return }
    stop()
    onStop?(.deviceChanged)
  }
}
