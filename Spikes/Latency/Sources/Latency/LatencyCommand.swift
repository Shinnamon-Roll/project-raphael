import Foundation
import UrielCore

/// The latency spike's command line (docs/plan.md, Phase 0 step 6).
@main
enum LatencyCommand {
  static let usage = """
    usage: latency <mode> [options]

      dry-run [--budget USD]  the whole matrix against a scripted fake API: no key, no network,
                              no cost. Its cost line estimates a real run's.
      smoke                   exactly one real request (Haiku 5.5, low), to check the key and
                              answer the keychain prompt once with Always Allow.
      run [--budget USD]      the whole matrix against the Claude API. It stops before any
                              request that could pass the budget (default $3.00).
      tts                     time from speak to didStart for about 30 sentences, silently.
      report [DIR]            summary.md and the blind rating sheet from a results folder
                              (default: the newest one).

    Results go to Spikes/Latency/results/, which git ignores. The API key comes only from the
    login keychain (service com.shinnamon.uriel, account anthropic-api-key).
    """

  /// Warm runs of each utterance per configuration; each also runs once cold.
  static let warmRounds = 10

  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    do {
      switch arguments.first {
      case "dry-run":
        try await matrix(
          mode: "dry-run", key: "dry-run-no-key",
          transport: ScriptedTransport(eventDelay: .milliseconds(1)),
          budget: budget(from: arguments))
      case "smoke": try await smoke()
      case "run":
        let budget = try budget(from: arguments)
        try await matrix(
          mode: "run", key: try await keychainKey(), transport: URLSessionTransport(),
          budget: budget)
      case "tts": try await tts()
      case "report":
        guard
          let directory = arguments.count > 1
            ? ResultsDirectory(url: URL(filePath: arguments[1], directoryHint: .isDirectory))
            : ResultsDirectory.newest(holding: "turns.jsonl")
        else { throw SpikeError("No results yet: run dry-run, smoke or run first.") }
        print(try writeReport(in: directory))
      case nil, "-h", "--help", "help": print(usage)
      default:
        print(usage)
        exit(64)
      }
    } catch {
      FileHandle.standardError.write(Data("latency: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func budget(from arguments: [String]) throws -> Double {
    guard let flag = arguments.firstIndex(of: "--budget") else { return 3.00 }
    guard arguments.indices.contains(flag + 1), let budget = Double(arguments[flag + 1]),
      budget > 0
    else { throw SpikeError("--budget needs an amount in dollars, such as 2.50.") }
    return budget
  }

  /// Reads the key once. The first read by a newly built spike shows a keychain prompt.
  private static func keychainKey() async throws -> String {
    let store = KeychainAPIKeyStore()
    do {
      return try await store.apiKey()
    } catch APIKeyError.missing {
      throw SpikeError(
        """
        No Claude API key is stored (login keychain, service \(store.service), account \
        \(store.account)). Store it, then run this again:

          security add-generic-password -U -s \(store.service) -a \(store.account) -w
        """)
    } catch APIKeyError.keychain(let status) {
      throw SpikeError(
        "The keychain refused the key (OSStatus \(status)). If you denied the prompt, run "
          + "`latency smoke` again and choose Always Allow.")
    }
  }

  /// Runs the whole matrix through `transport`, then writes the report next to the results.
  private static func matrix(
    mode: String, key: String, transport: any HTTPTransport, budget: Double
  ) async throws {
    let directory = try ResultsDirectory.create(mode: mode)
    print("Results: \(directory.url.path(percentEncoded: false))")
    var info = RunInfo(
      mode: mode, started: .now, budget: budget, configs: [], warmRounds: warmRounds)
    let runner = ConversationRunner(transport: transport, key: key)
    var spending = Budget(cap: budget)
    var configs = Configuration.all
    for config in Configuration.all where config.thinking == .disabled {
      let types = try await thinkingTypes(of: config.model, key: key, transport: transport)
      let answer = await disabledThinkingSupport(
        of: config, types: types, runner: runner, budget: &spending)
      for turn in answer.probe { try directory.append(turn) }
      print(
        "Models API: \(config.model) thinking types [\(types.keys.joined(separator: ", "))]; "
          + "`\(config.id)` \(answer.supported ? "runs" : "is skipped"): \(answer.reason).")
      if !answer.supported {
        info.skipped[config.id] = "\(config.model) does not accept it: \(answer.reason)."
        configs.removeAll { $0.id == config.id }
      }
    }
    info.configs = configs.map(\.id)
    let order = Matrix.schedule(
      configs: configs, utterances: Fixtures.utterances, warmRounds: warmRounds)
    print(
      "\(order.count) conversations; prefix about \(Fixtures.estimatedPrefixTokens) tokens "
        + "(the cache needs 512); budget $\(String(format: "%.2f", budget)).")
    try directory.write(info, to: "run.json")

    var matrix = Matrix(runner: runner, configs: configs, directory: directory, budget: spending)
    info.stop = try await matrix.run(warmRounds: warmRounds)
    info.spent = matrix.budget.spent
    try directory.write(info, to: "run.json")
    print(try writeReport(in: directory))
    if let stop = info.stop { throw SpikeError("Stopped early: \(stop).") }
  }

  /// One real request, so the owner answers the keychain prompt once before the full run.
  private static func smoke() async throws {
    let key = try await keychainKey()
    guard let config = Configuration.named("haiku-low"), let utterance = Fixtures.utterances.first
    else { return }
    let directory = try ResultsDirectory.create(mode: "smoke")
    var runner = ConversationRunner(transport: URLSessionTransport(), key: key)
    runner.maxRequestsPerTurn = 1
    var budget = Budget(cap: 0.05)
    let outcome = await runner.run(
      utterance.firstTurnOnly, config: config, sessionTag: Matrix.newSessionTag(), phase: .smoke,
      round: 0, budget: &budget)
    try directory.write(
      RunInfo(
        mode: "smoke", started: .now, budget: budget.cap, configs: [config.id], warmRounds: 0,
        spent: budget.spent, stop: outcome.stop),
      to: "run.json")
    for turn in outcome.turns { try directory.append(turn) }
    guard let request = outcome.turns.first?.requests.first else { return }
    if let error = request.error { throw SpikeError("The smoke request failed: \(error)") }
    let tokens = request.tokens ?? TokenCounts()
    print(
      """
      Smoke request (\(config.label)) worked.
        first text \(milliseconds(request.firstTextDelta)), first sentence \
      \(milliseconds(request.firstSentence)), total \(milliseconds(request.total)), \
      stop \(request.stopReason ?? "none"), \(request.sentences.count) sentences
        tokens: input \(tokens.input), output \(tokens.output), cache write \(tokens.cacheWrite), \
      cache read \(tokens.cacheRead); cost \(String(format: "$%.5f", request.cost))
      Results: \(directory.url.path(percentEncoded: false))
      """)
  }

  private static func tts() async throws {
    let sentences = sampleSentences()
    print("Speaking \(sentences.count) sentences at volume 0…")
    let result = try await measureSpeechStart(sentences: sentences)
    let directory = try ResultsDirectory.create(mode: "tts")
    try directory.write(result, to: "tts.json")
    print(
      """
      Voice: \(result.voiceName) (\(result.voiceIdentifier), \(result.quality))
      speak → didStart: first \(milliseconds(result.cold)); later \(result.warm.count): \
      p50 \(milliseconds(percentile(50, of: result.warm))), \
      p95 \(milliseconds(percentile(95, of: result.warm)))
      Results: \(directory.url.path(percentEncoded: false))
      """)
  }

  /// Writes `summary.md`, `blind-sheet.md` and `blind-key.md` into `directory`, and returns the
  /// summary.
  private static func writeReport(in directory: ResultsDirectory) throws -> String {
    let speech = try ResultsDirectory.newest(holding: "tts.json").map {
      try $0.read(SpeechStartResult.self, from: "tts.json")
    }
    let report = Report(
      name: directory.url.lastPathComponent,
      info: try directory.read(RunInfo.self, from: "run.json"),
      turns: try directory.turns(), speech: speech)
    let blind = report.blindSheet
    try directory.write(text: report.summary, to: "summary.md")
    try directory.write(text: blind.sheet, to: "blind-sheet.md")
    try directory.write(text: blind.key, to: "blind-key.md")
    return report.summary
  }
}
