import Testing
import UrielCore

@MainActor
private final class FakeSource: AudioSource {
  var onStop: ((AudioSourceError) -> Void)?
  var startError: (any Error)?
  private(set) var starts = 0
  private(set) var isCapturing = false

  func start() throws {
    starts += 1
    if let startError { throw startError }
    isCapturing = true
  }

  func stop() { isCapturing = false }

  /// Stops as `AudioEngineSource` does when the input device changes.
  func stopByItself() {
    isCapturing = false
    onStop?(.deviceChanged)
  }
}

/// Answers at once with `granted`, or, while `holds` is set, waits until ``answer(_:)``.
@MainActor
private final class FakePermission: MicrophonePermission {
  var granted = true
  var holds = false
  private(set) var requests = 0
  private var pending: [CheckedContinuation<Bool, Never>] = []
  var waiting: Int { pending.count }

  func request() async -> Bool {
    requests += 1
    guard holds else { return granted }
    return await withCheckedContinuation { pending.append($0) }
  }

  func answer(_ granted: Bool) {
    for continuation in pending { continuation.resume(returning: granted) }
    pending = []
  }
}

/// Lets other main-actor tasks run until `condition` holds, for at most 1000 yields.
@MainActor
private func yield(until condition: () -> Bool) async {
  for _ in 0..<1000 where !condition() { await Task.yield() }
}

@MainActor
@Suite("Microphone")
struct MicrophoneTests {
  private let source = FakeSource()
  private let permission = FakePermission()
  private let microphone: Microphone

  init() { microphone = Microphone(source: source, permission: permission) }

  @Test func switchesOnAndOff() async {
    #expect(microphone.state == .off)
    await microphone.turnOn()
    #expect(microphone.state == .on)
    #expect(source.isCapturing)
    microphone.turnOff()
    #expect(microphone.state == .off)
    #expect(!source.isCapturing)
  }

  @Test func deniedPermissionNeverStartsTheSource() async {
    permission.granted = false
    await microphone.turnOn()
    #expect(microphone.state == .denied)
    #expect(source.starts == 0)
  }

  @Test func deniedThenGrantedOnTheNextSwitchOnTurnsOn() async {
    permission.granted = false
    await microphone.turnOn()
    #expect(microphone.state == .denied)

    permission.granted = true
    await microphone.turnOn()
    #expect(microphone.state == .on)
    #expect(source.starts == 1)
  }

  @Test func sourceStoppingByItselfIsReportedAndCanBeRetried() async {
    await microphone.turnOn()
    source.stopByItself()
    #expect(microphone.state == .failed(reason: "The microphone changed. Switch it on again."))

    await microphone.turnOn()
    #expect(microphone.state == .on)
    #expect(source.starts == 2)
  }

  @Test func sourceStoppingWhileOffChangesNothing() {
    source.stopByItself()
    #expect(microphone.state == .off)
  }

  @Test func sourceFailureIsReportedAndCanBeRetried() async {
    source.startError = AudioSourceError.noInputDevice
    await microphone.turnOn()
    #expect(microphone.state == .failed(reason: "No microphone found."))
    #expect(!source.isCapturing)

    source.startError = nil
    await microphone.turnOn()
    #expect(microphone.state == .on)
  }

  @Test func switchingOffWhileAskingCancelsTheSwitchOn() async {
    permission.holds = true
    let switchOn = Task { await microphone.turnOn() }
    await yield { permission.waiting == 1 }
    #expect(microphone.state == .starting)

    microphone.turnOff()
    #expect(microphone.state == .off)
    permission.answer(true)
    await switchOn.value
    #expect(microphone.state == .off)
    #expect(source.starts == 0)
  }

  @Test func switchingOnAgainWhileStartingAsksOnce() async {
    permission.holds = true
    let switchOn = Task { await microphone.turnOn() }
    await yield { permission.waiting == 1 }
    await microphone.turnOn()  // Returns at once: already starting.
    permission.answer(true)
    await switchOn.value
    #expect(microphone.state == .on)
    #expect(permission.requests == 1)
    #expect(source.starts == 1)
  }

  @Test func offOnOffWhileAskingEndsOff() async {
    permission.holds = true
    let first = Task { await microphone.turnOn() }
    await yield { permission.waiting == 1 }
    microphone.turnOff()
    let second = Task { await microphone.turnOn() }
    await yield { permission.waiting == 2 }
    microphone.turnOff()

    permission.answer(true)
    await first.value
    await second.value
    #expect(microphone.state == .off)
    #expect(source.starts == 0)
  }

  @Test func theLatestSwitchOnWinsAfterOffAndOnWhileAsking() async {
    permission.holds = true
    let first = Task { await microphone.turnOn() }
    await yield { permission.waiting == 1 }
    microphone.turnOff()
    let second = Task { await microphone.turnOn() }
    await yield { permission.waiting == 2 }

    permission.answer(true)
    await first.value
    await second.value
    #expect(microphone.state == .on)
    #expect(source.starts == 1)
  }
}
