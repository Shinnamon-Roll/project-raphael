import Foundation
import Synchronization
import UrielCore

/// Where a conversation sits in the run, which decides the state of the prompt cache.
enum Phase: String, Codable, Sendable {
  /// The first request misses the cache: a fresh session tag changes the start of the prefix.
  case cold
  /// One request per configuration that writes its warm cache entry; left out of the statistics.
  case prime
  /// The prefix was used moments ago, so it is read from the cache.
  case warm
  /// The single request of `smoke`.
  case smoke
  /// One request that checks whether a configuration's settings are accepted; left out of the
  /// statistics.
  case probe
}

/// The measures of one request. Times are in seconds.
struct RequestMeasure: Codable, Sendable {
  /// From the end of the owner's utterance (the start of the turn) to the start of this request.
  var startOffset: Double
  /// From the start of this request; `nil` when the request failed or had no text.
  var firstTextDelta: Double?
  var firstSentence: Double?
  /// Between each later sentence and the one before it.
  var sentenceGaps: [Double] = []
  var total: Double?
  var stopReason: String?
  var tokens: TokenCounts?
  var cost = 0.0
  /// The stream broke after the request was accepted, so the cost is its worst case, not usage.
  var costIsWorstCase = false
  var attempts = 0
  var error: String?
  /// The status of an HTTP error response.
  var httpStatus: Int?
  /// The request failed on the network, before or during the response.
  var networkFailure = false
  /// Each call as `name {json input}`.
  var toolCalls: [String] = []
  /// Claude's answer as Uriel would speak it.
  var sentences: [String] = []
}

/// Whether a turn called the tool it should have, with the right arguments.
struct ToolCheck: Codable, Sendable, Hashable {
  var correct: Bool
  var note: String
}

/// One turn: one utterance and Uriel's answer, with every request in between.
struct TurnRecord: Codable, Sendable {
  var config: String
  var phase: Phase
  var round: Int
  var utterance: String
  var kind: Utterance.Kind
  /// 1 for the first turn of the conversation, 2 for the follow-up.
  var turn: Int
  var requests: [RequestMeasure] = []
  /// From the end of the owner's utterance to the first complete sentence of the turn, in seconds.
  var firstSentence: Double?
  var toolCheck = ToolCheck(correct: false, note: "not checked")

  var failed: Bool { requests.contains { $0.error != nil } }
}

/// Checks the calls of one turn against what the utterance asked for.
func checkToolCalls(_ calls: [ToolUse], expected: ExpectedTool?) -> ToolCheck {
  let names = calls.map(\.name).joined(separator: ", ")
  guard let expected else {
    return calls.isEmpty
      ? ToolCheck(correct: true, note: "no tool")
      : ToolCheck(correct: false, note: "called \(names)")
  }
  guard calls.count == 1, let call = calls.first else {
    return ToolCheck(correct: false, note: calls.isEmpty ? "no tool call" : "called \(names)")
  }
  func folded(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
  switch expected {
  case .openApp(let accepted):
    guard call.name == "open_app" else { return ToolCheck(correct: false, note: "called \(names)") }
    let name = call.input["name"]?.stringValue ?? ""
    let correct = accepted.contains { folded($0) == folded(name) }
    return ToolCheck(correct: correct, note: "open_app \"\(name)\"")
  case .setTimer(let seconds, let labels):
    guard call.name == "set_timer" else {
      return ToolCheck(correct: false, note: "called \(names)")
    }
    let duration = call.input["duration_seconds"]?.intValue
    let givenLabel = call.input["label"]?.stringValue ?? ""
    let correct =
      duration == seconds
      && (labels.map { $0.contains { folded(givenLabel).contains(folded($0)) } } ?? true)
    let given = duration.map(String.init) ?? "no whole number"
    return ToolCheck(correct: correct, note: "set_timer \(given) s \"\(givenLabel)\"")
  }
}

/// Runs conversations against Claude, one request at a time, and measures each request.
struct ConversationRunner: Sendable {
  private let client: ClaudeClient
  /// Counts responses, to tell a request that never got one from a stream that broke later.
  private let responses: ResponseCounter
  /// Voice answers are short; this only bounds a runaway answer and the worst-case cost.
  var maxTokens = 2_048
  var maxRequestsPerTurn = 3
  /// The language of the system prompt; the utterances come in it too.
  var language = Language.english
  /// The wait before the single retry when a 429 or 529 comes without `retry-after`.
  var fallbackRetryWait: Duration = .seconds(5)
  /// The longest `retry-after` honoured, so one answer cannot stall the run.
  static let maxRetryWait: Duration = .seconds(60)

  init(transport: any HTTPTransport, key: String) {
    let counting = CountingTransport(base: transport)
    responses = counting.responses
    client = ClaudeClient(keyProvider: InMemoryKey(key: key), transport: counting)
  }

  /// What a conversation produced, and why the whole run must stop, if it must.
  struct Outcome: Sendable {
    var turns: [TurnRecord]
    var stop: String?
  }

  /// The system prompt with a session tag in front, so a new tag means a new cache prefix.
  static func system(sessionTag: String, language: Language) -> [String] {
    ["Session \(sessionTag).", language.systemPrompt]
  }

  /// The request for the next answer of a conversation.
  func request(
    _ config: Configuration, sessionTag: String, messages: [Message]
  ) -> MessagesRequest {
    MessagesRequest(
      model: config.model, maxTokens: maxTokens,
      system: Self.system(sessionTag: sessionTag, language: language),
      tools: Fixtures.tools, messages: messages, effort: config.effort, thinking: config.thinking)
  }

  /// Runs every turn of `utterance` as one conversation. History is append-only (ADR 0008): each
  /// assistant message goes back exactly as received, so a 400 on a follow-up is a finding.
  func run(
    _ utterance: Utterance, config: Configuration, sessionTag: String, phase: Phase, round: Int,
    budget: inout Budget
  ) async -> Outcome {
    var messages: [Message] = []
    var turns: [TurnRecord] = []
    for (index, words) in utterance.turns.enumerated() {
      messages.append(Message(role: .user, content: [.text(words)]))
      let turnStart = ContinuousClock.now
      var record = TurnRecord(
        config: config.id, phase: phase, round: round, utterance: utterance.id,
        kind: utterance.kind, turn: index + 1)
      var calls: [ToolUse] = []
      var stop: String?
      var toolUseUnanswered = false
      for requestNumber in 1...maxRequestsPerTurn {
        let sent = await send(
          request(config, sessionTag: sessionTag, messages: messages), turnStart: turnStart,
          budget: &budget)
        record.requests.append(sent.measure)
        stop = sent.stop
        guard let response = sent.response else { break }
        messages.append(response.message)
        let uses = response.content.compactMap(\.toolUse)
        calls += uses
        guard response.stopReason == "tool_use", !uses.isEmpty else { break }
        guard requestNumber < maxRequestsPerTurn else {
          toolUseUnanswered = true
          break
        }
        // The tool call succeeds without doing anything, so the spoken reply after it is measured.
        messages.append(Message(role: .user, content: uses.map(Self.fakeResult(for:))))
      }
      record.firstSentence =
        record.requests.lazy.compactMap { request in
          request.firstSentence.map { request.startOffset + $0 }
        }.first
      record.toolCheck = checkToolCalls(calls, expected: index == 0 ? utterance.expected : nil)
      turns.append(record)
      if record.failed || stop != nil || toolUseUnanswered {
        return Outcome(turns: turns, stop: stop)
      }
    }
    return Outcome(turns: turns, stop: nil)
  }

  /// Sends one request within the budget, retrying once on 429 or 529, and measures it.
  private func send(
    _ request: MessagesRequest, turnStart: ContinuousClock.Instant, budget: inout Budget
  ) async -> (measure: RequestMeasure, response: ClaudeResponse?, stop: String?) {
    var measure = RequestMeasure(startOffset: (ContinuousClock.now - turnStart).seconds)
    guard let prices = Prices.of(request.model) else {
      measure.error = "no prices for \(request.model)"
      return (measure, nil, measure.error)
    }
    let worstCase = prices.worstCase(
      bodyBytes: (try? request.jsonData().count) ?? 0, maxTokens: request.maxTokens)
    while true {
      guard budget.allows(worstCase) else {
        measure.error = String(
          format: "not sent: up to $%.4f could pass the $%.2f budget", worstCase, budget.cap)
        return (measure, nil, "the budget cap")
      }
      measure.attempts += 1
      let responsesBefore = responses.count
      let start = ContinuousClock.now
      var attempt = measure
      attempt.startOffset = (start - turnStart).seconds
      attempt.error = nil
      do {
        let response = try await stream(request, start: start, into: &attempt)
        attempt.cost += prices.cost(of: TokenCounts(response.usage))
        budget.add(attempt.cost - measure.cost)
        return (attempt, response, nil)
      } catch {
        measure.error = Self.describe(error)
        var retryWait: Duration?
        switch error {
        case ClaudeError.http(let status, _, _, let retryAfter):
          // An HTTP error comes before any output, so nothing is billed.
          measure.httpStatus = status
          if status == 401 || status == 403 {
            return (measure, nil, "HTTP \(status): check the API key")
          }
          if status == 429 || status == 529 {
            retryWait = min(retryAfter ?? fallbackRetryWait, Self.maxRetryWait)
          }
        case is URLError where responses.count == responsesBefore:
          // No response came back, so the API never started an answer: nothing is billed.
          measure.networkFailure = true
        default:
          // The stream broke after the request was accepted, so it may be billed.
          measure.cost += worstCase
          measure.costIsWorstCase = true
          budget.add(worstCase)
          measure.networkFailure = error is URLError
          if case ClaudeError.stream(let type, _) = error,
            type == "overloaded_error" || type == "rate_limit_error"
          {
            retryWait = fallbackRetryWait
          }
        }
        guard let retryWait, measure.attempts < 2 else { return (measure, nil, nil) }
        try? await Task.sleep(for: retryWait)
      }
    }
  }

  /// Streams one request and fills in its times, as the voice would see the sentences arrive.
  private func stream(
    _ request: MessagesRequest, start: ContinuousClock.Instant, into measure: inout RequestMeasure
  ) async throws -> ClaudeResponse {
    var splitter = SentenceSplitter()
    var sentenceTimes: [Double] = []
    var response: ClaudeResponse?
    for try await event in client.stream(request) {
      let elapsed = (ContinuousClock.now - start).seconds
      let sentences: [String]
      switch event {
      case .textDelta(let text):
        if measure.firstTextDelta == nil { measure.firstTextDelta = elapsed }
        sentences = splitter.append(text)
      case .completed(let finished):
        sentences = splitter.flush()
        response = finished
      }
      measure.sentences += sentences
      sentenceTimes += Array(repeating: elapsed, count: sentences.count)
    }
    guard let response else { throw ClaudeError.invalidStream("the stream ended without a reply") }
    measure.total = (ContinuousClock.now - start).seconds
    measure.firstSentence = sentenceTimes.first
    measure.sentenceGaps = zip(sentenceTimes.dropFirst(), sentenceTimes).map { $0 - $1 }
    measure.stopReason = response.stopReason
    measure.tokens = TokenCounts(response.usage)
    measure.toolCalls = response.content.compactMap(\.toolUse).map { call in
      let input = (try? JSONValue.object(call.input).jsonData()).map {
        String(decoding: $0, as: UTF8.self)
      }
      return "\(call.name) \(input ?? "{}")"
    }
    return response
  }

  /// A successful result for a known tool, and an error for any other (ADR 0005).
  static func fakeResult(for call: ToolUse) -> ContentBlock {
    let content: String? =
      switch call.name {
      case "open_app": "Opened \(call.input["name"]?.stringValue ?? "the app")."
      case "set_timer":
        "Started a timer for \(call.input["duration_seconds"]?.intValue ?? 0) seconds."
      default: nil
      }
    return .toolResult(
      toolUseID: call.id, content: content ?? "Unknown tool: \(call.name).", isError: content == nil
    )
  }

  static func describe(_ error: any Error) -> String {
    switch error {
    case ClaudeError.http(let status, let type, let message, _):
      "HTTP \(status) \(type ?? "error"): \(message ?? "")"
    case ClaudeError.stream(let type, let message): "stream \(type): \(message)"
    case ClaudeError.invalidStream(let why): "invalid stream: \(why)"
    default: String(describing: error)
    }
  }
}

/// Wraps a transport and counts the responses it returned.
private struct CountingTransport: HTTPTransport {
  let base: any HTTPTransport
  let responses = ResponseCounter()

  func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
    let response = try await base.send(request)
    responses.increment()
    return response
  }
}

private final class ResponseCounter: Sendable {
  private let value = Mutex(0)

  var count: Int { value.withLock { $0 } }

  func increment() { value.withLock { $0 += 1 } }
}
