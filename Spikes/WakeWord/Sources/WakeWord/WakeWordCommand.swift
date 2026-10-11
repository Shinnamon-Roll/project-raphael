import Foundation

/// The wake-word spike's command line (docs/plan.md, Phase 0 step 7).
@main
enum WakeWordCommand {
  static let usage = """
    usage: wakeword <mode> [options]

      synth                   synthetic sessions made with `say` (Kanya in Thai, Samantha in
                              English) into audio/synthetic/, to try the pipeline without the
                              owner's voice.
      record calls --phrase uriel|hey-uriel --setting near|far|media [--count 20]
                              one recording; at each cue on screen, say the phrase and a short
                              Thai request. Saves the WAV and its label (the cue times).
      record background --kind media|talk --minutes N
                              audio with no wake phrase, saved every 10 minutes.
      replay --engine apple [--context on|off] [PATHS]
                              runs the engine over recordings (default: everything in audio/)
                              and writes results/<time>-replay-<engine>/summary.md.
      live --engine apple [--context on|off]
                              microphone → engine; prints each detection and the CPU per minute.

    --context on gives the Apple engine the wake phrase as contextual strings (default off).
    A mode refuses any flag it does not list. Recordings go to Spikes/WakeWord/audio/ and results
    to Spikes/WakeWord/results/; git ignores both, and nothing leaves this Mac. `record` and
    `live` need the microphone permission for the terminal, granted once in the prompt.
    """

  enum Command: Equatable {
    case help
    case synth
    case recordCalls(phrase: Phrase, setting: CallSetting, count: Int)
    case recordBackground(kind: BackgroundKind, minutes: Int)
    case replay(Engine, paths: [String])
    case live(Engine)
  }

  /// The engines replay and live mode can run.
  enum Engine: Equatable {
    case apple(context: Bool)

    var engine: any WakeWordEngine {
      switch self {
      case .apple(let context): AppleEngine(usesContext: context)
      }
    }
  }

  static func main() async {
    do {
      switch try parse(Array(CommandLine.arguments.dropFirst())) {
      case .help: print(usage)
      case .synth:
        let files = try Synth.run()
        print(
          "Wrote \(files.count) synthetic sessions to \(SpikePaths.synthetic.path(percentEncoded: false)):"
        )
        for file in files { print("  \(file.lastPathComponent)") }
      case .recordCalls(let phrase, let setting, let count):
        try await Recorder.recordCalls(phrase: phrase, setting: setting, count: count)
      case .recordBackground(let kind, let minutes):
        try await Recorder.recordBackground(kind: kind, minutes: minutes)
      case .replay(let engine, let paths):
        let urls = paths.isEmpty ? [SpikePaths.audio] : paths.map { URL(filePath: $0) }
        print(try await replay(engine.engine, paths: urls))
      case .live(let engine): try await live(engine.engine)
      }
    } catch {
      FileHandle.standardError.write(Data("wakeword: \(error)\n".utf8))
      exit(1)
    }
  }

  static func parse(_ arguments: [String]) throws -> Command {
    switch arguments.first {
    case nil, "-h", "--help", "help": return .help
    case "synth":
      _ = try Options(arguments.dropFirst(), mode: "synth", allowed: [])
      return .synth
    case "record":
      switch arguments.dropFirst().first {
      case "calls":
        let options = try Options(
          arguments.dropFirst(2), mode: "record calls",
          allowed: ["--phrase", "--setting", "--count"])
        return .recordCalls(
          phrase: try options.required("--phrase", Phrase.init),
          setting: try options.required("--setting", CallSetting.init),
          count: try options.optional("--count", positive) ?? 20)
      case "background":
        let options = try Options(
          arguments.dropFirst(2), mode: "record background", allowed: ["--kind", "--minutes"])
        return .recordBackground(
          kind: try options.required("--kind", BackgroundKind.init),
          minutes: try options.required("--minutes", positive))
      default: throw SpikeError("`record` needs `calls` or `background`. Run `wakeword help`.")
      }
    case "replay":
      let options = try Options(
        arguments.dropFirst(), mode: "replay", allowed: ["--engine", "--context"], takesPaths: true)
      return .replay(try engine(options), paths: options.positionals)
    case "live":
      let options = try Options(
        arguments.dropFirst(), mode: "live", allowed: ["--engine", "--context"])
      return .live(try engine(options))
    case let mode?: throw SpikeError("Unknown mode `\(mode)`. Run `wakeword help`.")
    }
  }

  private static func engine(_ options: Options) throws -> Engine {
    let context = try options.optional("--context") { ["on": true, "off": false][$0] } ?? false
    return try options.required("--engine") { $0 == "apple" ? .apple(context: context) : nil }
  }

  private static func positive(_ text: String) -> Int? {
    Int(text).flatMap { $0 > 0 ? $0 : nil }
  }

  /// `--flag value` pairs and the other arguments of one mode.
  struct Options {
    var mode: String
    var values: [String: String] = [:]
    var positionals: [String] = []

    /// Throws on a flag the mode does not take, a flag with no value, or a path where the mode
    /// takes none.
    init(
      _ arguments: ArraySlice<String>, mode: String, allowed: Set<String>, takesPaths: Bool = false
    ) throws {
      self.mode = mode
      var rest = arguments[...]
      while let argument = rest.popFirst() {
        guard argument.hasPrefix("--") else {
          positionals.append(argument)
          continue
        }
        guard allowed.contains(argument) else {
          throw SpikeError("`\(mode)` does not take \(argument). Run `wakeword help`.")
        }
        guard let value = rest.popFirst(), !value.hasPrefix("--") else {
          throw SpikeError("\(argument) needs a value. Run `wakeword help`.")
        }
        values[argument] = value
      }
      if !takesPaths, let extra = positionals.first {
        throw SpikeError("`\(mode)` does not take `\(extra)`. Run `wakeword help`.")
      }
    }

    func required<Value>(_ flag: String, _ parse: (String) -> Value?) throws -> Value {
      guard let value = try optional(flag, parse) else {
        throw SpikeError("`\(mode)` needs \(flag). Run `wakeword help`.")
      }
      return value
    }

    func optional<Value>(_ flag: String, _ parse: (String) -> Value?) throws -> Value? {
      guard let text = values[flag] else { return nil }
      guard let value = parse(text) else {
        throw SpikeError("\(flag) does not take `\(text)`. Run `wakeword help`.")
      }
      return value
    }
  }

  /// Microphone → engine, until Ctrl-C. For a manual check only.
  static func live(_ engine: some WakeWordEngine) async throws {
    try await engine.prepare()
    let microphone = try await Microphone()
    print(
      """
      Listening with \(engine.name) on \(microphone.deviceName). Say "Uriel" or "Hey Uriel"; \
      Ctrl-C stops.
      The orange microphone indicator stays on in the menu bar while this runs.
      """)
    let started = Date.now
    let countsService = engine.usesSpeechService
    let cpuReporter = Task {
      func read() -> (Double, Double?) {
        (processCPUSeconds(), countsService ? speechServiceCPUSeconds() : nil)
      }
      var last = read()
      while !Task.isCancelled {
        try await Task.sleep(for: .seconds(60))
        let now = read()
        let service = cpuDelta(from: last.1, to: now.1).map { String(format: "%.1f s", $0) }
        print(
          "  CPU in the last minute: this process \(String(format: "%.1f s", now.0 - last.0))"
            + (countsService
              ? ", speech service (localspeechrecognition) \(service ?? "not readable")" : ""))
        last = now
      }
    }
    defer { cpuReporter.cancel() }
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss.SSS"
    for try await event in engine.listen(to: microphone.chunks) {
      switch event {
      case .detection(let detection):
        print(
          "\(clock.string(from: .now))  \(detection.phrase.spoken) heard as “\(detection.heard)” "
            + "at \(String(format: "%.2f", detection.time)) s of audio")
      case .transcript(let words):
        print(
          "                heard: \(words.map(\.text).joined().trimmingCharacters(in: .whitespaces))"
        )
      }
    }
    microphone.stop()
    print("Stopped after \(Int(Date.now.timeIntervalSince(started))) s.")
  }
}
