import AVFoundation
import Observation

/// Captures microphone audio. ``AudioEngineSource`` is the real one; tests use a fake.
@MainActor
public protocol AudioSource: AnyObject {
  /// Starts capture. Starting a started source does nothing.
  func start() throws
  /// Stops capture. Stopping a stopped source does nothing.
  func stop()
  /// Called when capture stops by itself, after which the source counts as stopped.
  var onStop: ((AudioSourceError) -> Void)? { get set }
}

/// Asks the owner for microphone access. ``SystemMicrophonePermission`` is the real one.
@MainActor
public protocol MicrophonePermission {
  /// Returns whether Uriel may use the microphone. macOS prompts only the first time.
  func request() async -> Bool
}

/// The system's microphone permission, the TCC prompt that shows the `Info.plist` usage string.
public struct SystemMicrophonePermission: MicrophonePermission {
  public init() {}

  public func request() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }
}

/// The owner's microphone switch: the menu turns it on and off and shows its ``state``.
///
/// It starts off, and nothing switches it on but the owner. A switch-off always wins, even over a
/// switch-on still waiting for the permission prompt. When the source stops by itself, the state
/// says so.
@MainActor @Observable
public final class Microphone {
  public enum State: Sendable, Hashable {
    case off
    /// Asking for permission, then starting the source.
    case starting
    case on
    /// The owner has not let Uriel use the microphone.
    case denied
    /// The source could not start, or stopped by itself; `reason` is the error's description.
    case failed(reason: String)
  }

  public private(set) var state = State.off

  private let source: any AudioSource
  private let permission: any MicrophonePermission
  /// Counts switch-offs, so a switch-on that was waiting for permission sees it was overtaken.
  @ObservationIgnored private var switchOffs = 0

  public init(
    source: any AudioSource = AudioEngineSource(),
    permission: any MicrophonePermission = SystemMicrophonePermission()
  ) {
    self.source = source
    self.permission = permission
    source.onStop = { [weak self] error in self?.sourceStopped(error) }
  }

  /// Asks for permission, then starts the source. Does nothing while starting or on.
  public func turnOn() async {
    guard state != .starting, state != .on else { return }
    state = .starting
    let switchOffsBefore = switchOffs
    let granted = await permission.request()
    guard switchOffs == switchOffsBefore else { return }
    guard granted else {
      state = .denied
      return
    }
    do {
      // shortcut: the engine starts on the main actor and may block it for a moment; move the
      // source to its own actor if the menu stutters.
      try source.start()
      state = .on
    } catch {
      state = .failed(reason: error.localizedDescription)
    }
  }

  /// Stops the source, and cancels a switch-on that is still asking for permission.
  public func turnOff() {
    switchOffs += 1
    source.stop()
    state = .off
  }

  private func sourceStopped(_ error: AudioSourceError) {
    guard state == .on else { return }
    state = .failed(reason: error.localizedDescription)
  }
}
