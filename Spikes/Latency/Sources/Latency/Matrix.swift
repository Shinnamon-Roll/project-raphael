import Foundation
import UrielCore

/// One conversation of a run, in the order it is sent.
struct ScheduledConversation: Sendable {
  let phase: Phase
  let round: Int
  let utterance: Utterance
  let config: Configuration
}

/// What a run was and how it ended, kept as `run.json` next to its results.
struct RunInfo: Codable, Sendable {
  var mode: String
  var started: Date
  var budget: Double
  /// The configurations run, by ID, in order.
  var configs: [String]
  /// Configurations left out, by ID, with the reason.
  var skipped: [String: String] = [:]
  var warmRounds: Int
  var spent = 0.0
  /// Why the run stopped early, if it did.
  var stop: String?
}

/// The full matrix: every utterance once cold and `warmRounds` times warm, per configuration.
struct Matrix {
  let runner: ConversationRunner
  let configs: [Configuration]
  let directory: ResultsDirectory
  var budget: Budget

  /// The order of a run, chosen so the prompt cache behaves as in real use:
  ///
  /// 1. Cold: each utterance once per configuration, each conversation with a fresh session tag
  ///    at the start of the system prompt. Its first request misses the cache and writes it, as
  ///    the first request after more than 5 minutes idle does; its later requests (the follow-up,
  ///    the reply after a tool) read what it wrote, as they would in real use.
  /// 2. Prime: one request per configuration with that configuration's warm tag, so that the
  ///    first warm request already hits the cache.
  /// 3. Warm: `warmRounds` rounds, each going through the utterances and, for each, through the
  ///    configurations. Each configuration's cache entry is then seconds old, well inside its
  ///    5-minute TTL, and changes in API load spread evenly over the configurations.
  static func schedule(
    configs: [Configuration], utterances: [Utterance], warmRounds: Int
  ) -> [ScheduledConversation] {
    var order: [ScheduledConversation] = []
    for utterance in utterances {
      for config in configs {
        order.append(.init(phase: .cold, round: 0, utterance: utterance, config: config))
      }
    }
    if let first = utterances.first?.firstTurnOnly {
      for config in configs {
        order.append(.init(phase: .prime, round: 0, utterance: first, config: config))
      }
    }
    for round in stride(from: 1, through: warmRounds, by: 1) {
      for utterance in utterances {
        for config in configs {
          order.append(.init(phase: .warm, round: round, utterance: utterance, config: config))
        }
      }
    }
    return order
  }

  /// A random tag for the start of the system prompt; a new one is a new cache prefix.
  static func newSessionTag() -> String { String(UInt64.random(in: .min ... .max), radix: 16) }

  /// Runs the schedule, writing each turn as it ends. Returns why it stopped early, if it did.
  mutating func run(warmRounds: Int) async throws -> String? {
    let warmTags = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, Self.newSessionTag()) })
    let order = Self.schedule(
      configs: configs, utterances: Fixtures.utterances, warmRounds: warmRounds)
    var networkFailures = 0
    for (index, item) in order.enumerated() {
      let tag = item.phase == .cold ? Self.newSessionTag() : warmTags[item.config.id, default: ""]
      let outcome = await runner.run(
        item.utterance, config: item.config, sessionTag: tag, phase: item.phase, round: item.round,
        budget: &budget)
      for turn in outcome.turns { try directory.append(turn) }
      print(progressLine(item, outcome, number: index + 1, of: order.count))
      if let stop = outcome.stop { return stop }
      networkFailures = Self.networkFailureStreak(
        networkFailures, after: outcome.turns.flatMap(\.requests))
      if networkFailures >= Self.maxNetworkFailures {
        return "\(networkFailures) network failures in a row; check the internet connection, then "
          + "run again"
      }
    }
    return nil
  }

  /// The run stops after this many network failures in a row, rather than failing every request.
  static let maxNetworkFailures = 3

  /// Network failures in a row after `requests`: each one adds one, and a request that worked
  /// starts the count again. Other failures leave it as it is.
  static func networkFailureStreak(_ streak: Int, after requests: [RequestMeasure]) -> Int {
    requests.reduce(streak) { streak, request in
      request.networkFailure ? streak + 1 : request.error == nil ? 0 : streak
    }
  }

  private func progressLine(
    _ item: ScheduledConversation, _ outcome: ConversationRunner.Outcome, number: Int, of count: Int
  ) -> String {
    let turns = outcome.turns.map { turn in
      turn.failed
        ? "turn \(turn.turn) FAILED: \(turn.requests.last?.error ?? "")"
        : "turn \(turn.turn) \(milliseconds(turn.firstSentence))\(turn.toolCheck.correct ? "" : " (tool: \(turn.toolCheck.note))")"
    }
    let cost = outcome.turns.flatMap(\.requests).reduce(0) { $0 + $1.cost }
    return [
      "\(number)/\(count)".padding(toLength: 10, withPad: " ", startingAt: 0),
      "\(item.phase.rawValue) r\(item.round)".padding(toLength: 9, withPad: " ", startingAt: 0),
      item.utterance.id.padding(toLength: 8, withPad: " ", startingAt: 0),
      item.config.id.padding(toLength: 25, withPad: " ", startingAt: 0),
      turns.joined(separator: ", "),
      String(format: "· $%.4f · spent $%.4f of $%.2f", cost, budget.spent, budget.cap),
    ].joined(separator: " ")
  }
}

/// What the Models API says about one model's `thinking` types.
struct ThinkingTypes: Sendable, Hashable {
  /// The keys of `capabilities.thinking.types`, sorted.
  var keys: [String]
  /// `types.disabled.supported`, or `nil` when the API does not list `disabled`.
  var disabledSupported: Bool?
}

/// Asks the Models API (`GET /v1/models/{id}`) which `thinking` types `model` accepts.
func thinkingTypes(
  of model: String, key: String, transport: any HTTPTransport
) async throws -> ThinkingTypes {
  var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models/\(model)")!)
  request.setValue(key, forHTTPHeaderField: "x-api-key")
  request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
  let response = try await transport.send(request)
  var body = ""
  for try await line in response.lines {
    body += line + "\n"
    if body.utf8.count > 1_000_000 { break }  // A model object is a few KB.
  }
  let json = try? JSONValue(json: Data(body.utf8))
  guard (200..<300).contains(response.statusCode), let json else {
    let error = json?["error"]
    throw SpikeError(
      "The Models API check for \(model) failed: HTTP \(response.statusCode) "
        + "\(error?["type"]?.stringValue ?? ""): \(error?["message"]?.stringValue ?? "")")
  }
  let types = json["capabilities"]?["thinking"]?["types"]?.objectValue ?? [:]
  let disabled: Bool? =
    switch types["disabled"]?["supported"] {
    case .bool(let supported): supported
    default: nil
    }
  return ThinkingTypes(keys: types.keys.sorted(), disabledSupported: disabled)
}

/// Whether `config`, which sends `thinking: {type: "disabled"}`, can run, and why.
///
/// The Models API's answer decides. When it does not list `disabled`, one real request with the
/// configuration, inside `budget`, decides: a 400 means no. That request's turn is returned so
/// it is kept with the results.
func disabledThinkingSupport(
  of config: Configuration, types: ThinkingTypes, runner: ConversationRunner,
  budget: inout Budget
) async -> (supported: Bool, reason: String, probe: [TurnRecord]) {
  if let supported = types.disabledSupported {
    return (supported, "the Models API says \(supported ? "yes" : "no")", [])
  }
  guard let first = Fixtures.utterances.first?.firstTurnOnly else { return (false, "", []) }
  var probeRunner = runner
  probeRunner.maxRequestsPerTurn = 1
  let outcome = await probeRunner.run(
    first, config: config, sessionTag: Matrix.newSessionTag(), phase: .probe, round: 0,
    budget: &budget)
  let request = outcome.turns.first?.requests.first
  if request?.httpStatus == 400 {
    return (
      false, "the Models API does not say, and a probe request got: \(request?.error ?? "")",
      outcome.turns
    )
  }
  return (
    true,
    "the Models API does not say; a probe request "
      + (request?.error.map { "failed without a 400 (\($0)), so it runs" } ?? "worked"),
    outcome.turns
  )
}

/// A git-ignored folder of one run's raw results under `Spikes/Latency/results/`.
struct ResultsDirectory: Sendable {
  /// `Spikes/Latency/results`, found from this file, so it does not depend on the shell's folder.
  static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "results", directoryHint: .isDirectory)

  let url: URL

  /// A new folder named after the time and the mode, so names sort by time.
  static func create(mode: String) throws -> ResultsDirectory {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let url = root.appending(
      path: "\(formatter.string(from: .now))-\(mode)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return ResultsDirectory(url: url)
  }

  /// The newest results folder that holds `file`.
  static func newest(holding file: String) -> ResultsDirectory? {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
    return names.sorted().reversed().lazy
      .map { ResultsDirectory(url: root.appending(path: $0, directoryHint: .isDirectory)) }
      .first { FileManager.default.fileExists(atPath: $0.file(file).path(percentEncoded: false)) }
  }

  func file(_ name: String) -> URL { url.appending(path: name) }

  /// Appends one turn to `turns.jsonl`, so an interrupted run keeps what it measured.
  func append(_ turn: TurnRecord) throws {
    let path = file("turns.jsonl").path(percentEncoded: false)
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: file("turns.jsonl"))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Self.encoder.encode(turn) + Data("\n".utf8))
  }

  func turns() throws -> [TurnRecord] {
    let text = try String(contentsOf: file("turns.jsonl"), encoding: .utf8)
    return try text.split(separator: "\n").map {
      try Self.decoder.decode(TurnRecord.self, from: Data($0.utf8))
    }
  }

  func write(_ value: some Encodable, to name: String) throws {
    try Self.encoder.encode(value).write(to: file(name))
  }

  func read<Value: Decodable>(_ type: Value.Type, from name: String) throws -> Value {
    try Self.decoder.decode(type, from: Data(contentsOf: file(name)))
  }

  func write(text: String, to name: String) throws {
    try Data(text.utf8).write(to: file(name))
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// A failure the spike explains to the owner and exits on.
struct SpikeError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// The key, read once from the Keychain, so the run does not time a Keychain lookup per request.
struct InMemoryKey: APIKeyProvider, CustomStringConvertible, CustomDebugStringConvertible {
  let key: String

  func apiKey() async throws -> String { key }

  // Printing the provider never prints the key.
  var description: String { "API key (redacted)" }
  var debugDescription: String { description }
}

/// Seconds as whole milliseconds, or a dash when there is no value.
func milliseconds(_ seconds: Double?) -> String {
  seconds.map { "\(Int(($0 * 1_000).rounded())) ms" } ?? "–"
}
