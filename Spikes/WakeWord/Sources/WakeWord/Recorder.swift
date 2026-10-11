import AVFoundation
import Synchronization

/// The default input device as contiguous chunks of 16 kHz mono samples, through one
/// `AVAudioEngine` tap. The grant belongs to Terminal, the responsible process.
final class Microphone {
  let chunks: AsyncStream<[Float]>
  private let continuation: AsyncStream<[Float]>.Continuation
  private let engine = AVAudioEngine()
  private var interrupt: (any DispatchSourceSignal)?
  private var tap: Tap?

  init() async throws {
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      throw SpikeError(
        "The microphone is denied for this terminal. Allow it in System Settings › Privacy & "
          + "Security › Microphone, then run this again.")
    }
    (chunks, continuation) = AsyncStream<[Float]>.makeStream()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw SpikeError("There is no microphone input.")
    }
    let tap = Tap(converter: try FormatConverter(from: format, to: SpikeAudio.format))
    self.tap = tap
    let continuation = continuation
    input.installTap(
      onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format
    ) {
      buffer, _ in
      if let samples = tap.convert(buffer) { continuation.yield(samples) }
    }
    engine.prepare()
    try engine.start()
    // Ctrl-C ends the stream, so the caller saves what it recorded instead of dying mid-file.
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { continuation.finish() }
    source.resume()
    interrupt = source
  }

  func stop() {
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    continuation.finish()
    interrupt?.cancel()
    signal(SIGINT, SIG_DFL)
    if let tap, tap.failures.load(ordering: .relaxed) > 0 {
      print(
        "Warning: \(tap.failures.load(ordering: .relaxed)) microphone buffers could not be "
          + "converted and are missing from the audio.")
    }
  }

  /// Converts each tap buffer to 16 kHz mono, and counts the buffers it could not convert.
  private final class Tap: @unchecked Sendable {
    // Safe: AVAudioEngine calls the tap block serially on its own thread, and the tap block is
    // the only code that touches `converter`; `failures` is atomic.
    private let converter: FormatConverter
    let failures = Atomic<Int>(0)
    init(converter: FormatConverter) { self.converter = converter }
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
      guard let converted = try? converter.convert(buffer) else {
        failures.add(1, ordering: .relaxed)
        return nil
      }
      return SpikeAudio.samples(of: converted)
    }
  }
}

/// The settings of a calls session (docs/plan.md, Phase 0 step 7).
enum CallSetting: String, CaseIterable, Sendable {
  case near, far, media

  var instruction: String {
    switch self {
    case .near: "Sit about 0.5 m from the Mac, in a quiet room."
    case .far: "Stand or sit about 3 m from the Mac, in a quiet room."
    case .media:
      "Sit at your usual distance with a video or music playing out loud on the Mac or nearby."
    }
  }
}

enum BackgroundKind: String, CaseIterable, Sendable {
  case media, talk
}

/// Records the owner's calls and background audio into `Spikes/WakeWord/audio/`.
enum Recorder {
  /// Short Thai requests the cue suggests after the wake phrase, as the owner would talk to Uriel.
  static let requests = [
    "ตั้งเวลาห้านาที", "เปิด Safari ให้หน่อย", "วันนี้อากาศเป็นยังไง", "เปิดเพลงให้หน่อย",
    "ตั้งเวลาสิบนาทีนะ", "เล่าเรื่องตลกให้ฟังหน่อย", "เปิด Notes ให้หน่อย", "ตอนนี้กี่โมงแล้ว",
  ]

  /// The audio times of `count` cues: the first after 4–6 s, then every 8–12 s, so a cue's window
  /// (6 s) never reaches the next cue.
  static func cueTimes(count: Int, using generator: inout some RandomNumberGenerator) -> [Double] {
    var times: [Double] = []
    var time = Double.random(in: 4...6, using: &generator)
    for _ in 0..<count {
      times.append(time)
      time += Double.random(in: 8...12, using: &generator)
    }
    return times
  }

  /// One continuous recording; at each cue the terminal shows what to say. The cue is text only,
  /// because a spoken cue would be recorded.
  static func recordCalls(phrase: Phrase, setting: CallSetting, count: Int) async throws {
    var generator = SystemRandomNumberGenerator()
    let times = cueTimes(count: count, using: &generator)
    let minutes = ((times.last ?? 0) + SessionLabel.defaultWindow + 2) / 60
    print(
      """
      Calls session: "\(phrase.spoken)", \(setting.rawValue), \(count) calls, about \
      \(Int(minutes.rounded(.up))) min.

        \(setting.instruction)
        When a cue appears, say "\(phrase.spoken)" and then the short Thai request it shows, the
        way you would talk to Uriel. Say nothing between cues. The cue is on screen only.
        Ctrl-C stops early and keeps what was recorded.

      Press Return to start.
      """)
    _ = readLine()
    let url = SpikePaths.audio.appending(
      path: "calls-\(phrase.rawValue)-\(setting.rawValue)-\(SpikePaths.stamp()).wav")
    let writer = try WAVWriter(url: url)
    let microphone = try await Microphone()
    print("Recording. Wait for the first cue…")
    var cues: [Cue] = []
    var waiting = true
    for await samples in microphone.chunks {
      try writer.append(samples)
      let now = writer.duration
      if cues.count < times.count, now >= times[cues.count] {
        let request = requests[cues.count % requests.count]
        cues.append(Cue(time: now, text: "\(phrase.spoken) … \(request)"))
        print("\n  >>> \(cues.count)/\(count)   Say: \"\(phrase.spoken)\" … \(request)")
        waiting = false
      } else if !waiting, let last = cues.last, now >= last.time + SessionLabel.defaultWindow {
        print("      (wait)")
        waiting = true
      }
      if cues.count == times.count, let last = cues.last,
        now >= last.time + SessionLabel.defaultWindow + 2
      {
        break
      }
    }
    microphone.stop()
    writer.close()
    try SessionLabel(
      kind: .calls, phrase: phrase, setting: setting.rawValue, recorded: .now,
      duration: writer.duration, window: SessionLabel.defaultWindow, cues: cues
    ).write(for: url)
    print("\nSaved \(cues.count) calls, \(String(format: "%.0f", writer.duration)) s: \(url.path)")
  }

  /// Ten minutes per file, so a crash loses little.
  static let chunkSeconds = 600.0

  /// Continuous audio with no wake phrase, in chunks, each with its own label.
  static func recordBackground(kind: BackgroundKind, minutes: Int) async throws {
    let advice =
      switch kind {
      case .media: "Play podcasts, TV or videos in Thai near the Mac at a normal volume."
      case .talk:
        """
        Talk normally in Thai near the Mac: calls, chats, reading aloud. Now and then also say the
          Thai near-words, such as "ยูเรีย" (urea) and "ยูริ", inside sentences.
        """
      }
    print(
      """
      Background: \(kind.rawValue), \(minutes) min, saved every \(Int(chunkSeconds / 60)) min.

        \(advice)
        Never say "Uriel" or "Hey Uriel" in this recording.
        Ctrl-C stops early and keeps what was recorded.

      Press Return to start.
      """)
    _ = readLine()
    let stamp = SpikePaths.stamp()
    var part = 1
    func makeWriter() throws -> WAVWriter {
      try WAVWriter(
        url: SpikePaths.audio.appending(
          path: "background-\(kind.rawValue)-\(stamp)-\(String(format: "%02d", part)).wav"))
    }
    func save(_ writer: WAVWriter) throws {
      writer.close()
      guard writer.frames > 0 else {
        try? FileManager.default.removeItem(at: writer.url)
        return
      }
      try SessionLabel(
        kind: .background, phrase: nil, setting: kind.rawValue, recorded: .now,
        duration: writer.duration, window: SessionLabel.defaultWindow, cues: []
      ).write(for: writer.url)
      print(
        "Saved \(writer.url.lastPathComponent) (\(String(format: "%.1f", writer.duration / 60)) min)."
      )
    }
    var writer = try makeWriter()
    var total = 0.0
    let microphone = try await Microphone()
    print("Recording…")
    for await samples in microphone.chunks {
      try writer.append(samples)
      let before = total
      total += Double(samples.count) / SpikeAudio.sampleRate
      if Int(total / 60) > Int(before / 60) { print("  \(Int(total / 60))/\(minutes) min") }
      if writer.duration >= chunkSeconds {
        try save(writer)
        part += 1
        writer = try makeWriter()
      }
      if total >= Double(minutes) * 60 { break }
    }
    microphone.stop()
    try save(writer)
  }
}
