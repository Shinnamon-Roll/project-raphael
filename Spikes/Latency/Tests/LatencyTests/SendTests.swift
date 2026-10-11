import Foundation
import Testing
import UrielCore

@testable import Latency

/// One scripted answer of `ScriptTransport`.
private enum Step: Sendable {
  /// An HTTP response with these body lines; the body then ends, or fails with `error`.
  case respond(
    status: Int, headers: [String: String] = [:], lines: [String], error: URLError? = nil)
  /// No response at all.
  case fail(URLError)
}

private actor Script {
  private var steps: [Step]
  private(set) var requests: [URLRequest] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  func next(_ request: URLRequest) -> Step {
    requests.append(request)
    return steps.isEmpty ? .fail(URLError(.resourceUnavailable)) : steps.removeFirst()
  }
}

/// Answers each request with the next step of its script.
private struct ScriptTransport: HTTPTransport {
  let script: Script

  func send(_ request: URLRequest) async throws -> HTTPStreamResponse {
    switch await script.next(request) {
    case .fail(let error): throw error
    case .respond(let status, let headers, let lines, let error):
      return HTTPStreamResponse(
        statusCode: status, headers: headers,
        lines: AsyncThrowingStream { continuation in
          for line in lines { continuation.yield(line) }
          continuation.finish(throwing: error)
        })
    }
  }
}

private let started = [
  "event: message_start",
  #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":1}}}"#,
  "",
]

private let answered =
  started + [
    "event: content_block_start",
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    "",
    "event: content_block_delta",
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi."}}"#,
    "",
    "event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#, "",
    "event: message_delta",
    #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}"#,
    "",
    "event: message_stop", #"data: {"type":"message_stop"}"#, "",
  ]

private let overloaded =
  started + [
    "event: error",
    #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, "",
  ]

private func error(_ status: Int, _ type: String) -> Step {
  .respond(
    status: status, headers: ["retry-after": "0"],
    lines: [#"{"type":"error","error":{"type":"\#(type)","message":"scripted"}}"#])
}

/// The cost of `answered` on Haiku: (10 × 0.10 + 20 × 0.50 + 1000 × 0.01) per million.
private let answeredCost = 0.000_021

private let haiku = Configuration.named("haiku-low")!
private let firstTurn = Fixtures.utterances[0].firstTurnOnly

private func runner(_ script: Script) -> ConversationRunner {
  var runner = ConversationRunner(transport: ScriptTransport(script: script), key: "test")
  runner.maxRequestsPerTurn = 1
  runner.fallbackRetryWait = .zero
  return runner
}

/// Runs the first turn of chat-1 against `steps`.
private func run(_ steps: [Step], cap: Double = 3) async -> (
  outcome: ConversationRunner.Outcome, budget: Budget, sent: Int
) {
  let script = Script(steps)
  var budget = Budget(cap: cap)
  let outcome = await runner(script).run(
    firstTurn, config: haiku, sessionTag: "t", phase: .cold, round: 0, budget: &budget)
  return (outcome, budget, await script.requests.count)
}

/// The worst case of that request, as the runner computes it.
private func worstCase() throws -> Double {
  let request = runner(Script([])).request(
    haiku, sessionTag: "t", messages: [Message(role: .user, content: [.text(firstTurn.turns[0])])])
  return try #require(Prices.of(haiku.model)).worstCase(
    bodyBytes: try request.jsonData().count, maxTokens: request.maxTokens)
}

private func only(_ outcome: ConversationRunner.Outcome) throws -> RequestMeasure {
  try #require(outcome.turns.first?.requests.first)
}

@Suite("Retries, failures and the money they cost")
struct SendTests {
  @Test func rateLimitThenSuccessCountsTheCostOnce() async throws {
    let (outcome, budget, sent) = await run([
      error(429, "rate_limit_error"), .respond(status: 200, lines: answered),
    ])
    let request = try only(outcome)
    #expect(sent == 2)
    #expect(request.attempts == 2)
    #expect(request.error == nil)
    #expect(abs(request.cost - answeredCost) < 1e-12)
    #expect(abs(budget.spent - answeredCost) < 1e-12)
    #expect(outcome.stop == nil)
  }

  @Test func rateLimitTwiceIsRecordedWithoutAThirdAttempt() async throws {
    let (outcome, budget, sent) = await run([
      error(429, "rate_limit_error"), error(529, "overloaded_error"),
      .respond(status: 200, lines: answered),
    ])
    let request = try only(outcome)
    #expect(sent == 2)
    #expect(request.attempts == 2)
    #expect(request.httpStatus == 529)
    #expect(request.error?.hasPrefix("HTTP 529") == true)
    #expect(request.cost == 0 && budget.spent == 0)
    #expect(outcome.stop == nil)
  }

  @Test func streamBrokenAfterAcceptanceIsChargedTheWorstCase() async throws {
    let worst = try worstCase()
    let (outcome, budget, sent) = await run([.respond(status: 200, lines: started)])
    let request = try only(outcome)
    #expect(sent == 1)
    #expect(request.costIsWorstCase)
    #expect(abs(request.cost - worst) < 1e-12)
    #expect(abs(budget.spent - worst) < 1e-12)
    #expect(!request.networkFailure)
  }

  @Test func networkLossAfterTheResponseIsChargedTheWorstCase() async throws {
    let worst = try worstCase()
    let (outcome, budget, _) = await run([
      .respond(status: 200, lines: started, error: URLError(.networkConnectionLost))
    ])
    let request = try only(outcome)
    #expect(request.networkFailure)
    #expect(abs(budget.spent - worst) < 1e-12)
  }

  @Test func networkFailureBeforeAnyResponseIsNotCharged() async throws {
    let (outcome, budget, sent) = await run([.fail(URLError(.notConnectedToInternet))])
    let request = try only(outcome)
    #expect(sent == 1)
    #expect(request.networkFailure)
    #expect(request.cost == 0 && budget.spent == 0 && !request.costIsWorstCase)
    #expect(outcome.stop == nil)
  }

  @Test func unauthorizedStopsTheRun() async throws {
    let (outcome, _, sent) = await run([error(401, "authentication_error")])
    #expect(sent == 1)
    #expect(outcome.stop == "HTTP 401: check the API key")
  }

  @Test func budgetIsCheckedAgainBeforeTheRetry() async throws {
    let worst = try worstCase()
    // The overloaded stream is charged its worst case, so a second one no longer fits.
    let (outcome, budget, sent) = await run(
      [.respond(status: 200, lines: overloaded), .respond(status: 200, lines: answered)],
      cap: worst * 1.5)
    let request = try only(outcome)
    #expect(sent == 1)
    #expect(request.attempts == 1)
    #expect(request.error?.hasPrefix("not sent") == true)
    #expect(outcome.stop == "the budget cap")
    #expect(abs(budget.spent - worst) < 1e-12)
  }

  @Test func networkFailuresInARowAreCountedUntilARequestWorks() {
    var failed = RequestMeasure(startOffset: 0)
    failed.error = "network"
    failed.networkFailure = true
    let worked = RequestMeasure(startOffset: 0)
    var other = RequestMeasure(startOffset: 0)
    other.error = "HTTP 500"
    #expect(Matrix.networkFailureStreak(0, after: [failed, failed]) == 2)
    #expect(Matrix.networkFailureStreak(2, after: [other]) == 2)
    #expect(Matrix.networkFailureStreak(2, after: [worked]) == 0)
    #expect(Matrix.networkFailureStreak(2, after: [worked, failed]) == 1)
  }

  @Test func modelsAPIAnswerIsReadAndAMissingDisabledIsUnknown() async throws {
    func types(_ json: String) async throws -> ThinkingTypes {
      try await thinkingTypes(
        of: Configuration.haiku, key: "test",
        transport: ScriptTransport(script: Script([.respond(status: 200, lines: [json])])))
    }
    let listed = try await types(
      #"{"capabilities":{"thinking":{"types":{"adaptive":{"supported":true},"disabled":{"supported":false}}}}}"#
    )
    #expect(listed == ThinkingTypes(keys: ["adaptive", "disabled"], disabledSupported: false))
    let missing = try await types(
      #"{"capabilities":{"thinking":{"types":{"adaptive":{"supported":true}}}}}"#)
    #expect(missing == ThinkingTypes(keys: ["adaptive"], disabledSupported: nil))
  }

  @Test func unknownDisabledThinkingIsSettledByOneProbeRequest() async throws {
    let config = try #require(Configuration.named("haiku-low-disabled"))
    let unknown = ThinkingTypes(keys: ["adaptive"], disabledSupported: nil)
    for (steps, supported) in [
      ([error(400, "invalid_request_error")], false),
      ([.respond(status: 200, lines: answered)], true),
    ] as [([Step], Bool)] {
      let script = Script(steps)
      var budget = Budget(cap: 3)
      let answer = await disabledThinkingSupport(
        of: config, types: unknown, runner: runner(script), budget: &budget)
      #expect(answer.supported == supported)
      #expect(await script.requests.count == 1)
      #expect(answer.probe.map(\.phase) == [.probe])
    }
    // When the Models API answers, no request is sent.
    let script = Script([])
    var budget = Budget(cap: 3)
    let answer = await disabledThinkingSupport(
      of: config, types: ThinkingTypes(keys: ["disabled"], disabledSupported: false),
      runner: runner(script), budget: &budget)
    #expect(!answer.supported)
    #expect(await script.requests.isEmpty)
  }
}
