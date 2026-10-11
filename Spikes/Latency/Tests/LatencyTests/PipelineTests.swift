import Foundation
import Testing
import UrielCore

@testable import Latency

private func runner() -> ConversationRunner {
  ConversationRunner(transport: ScriptedTransport(), key: "test")
}

private func fixture(_ id: String) throws -> Utterance {
  try #require(Fixtures.utterances.first { $0.id == id })
}

private func config(_ id: String) throws -> Configuration {
  try #require(Configuration.named(id))
}

@Suite("Conversations against the scripted API")
struct PipelineTests {
  @Test func chatFollowUpSendsHistoryBackAndReadsTheCache() async throws {
    let chat = try fixture("chat-2")
    var budget = Budget(cap: 3)
    let outcome = await runner().run(
      chat, config: try config("sonnet-low"), sessionTag: "a", phase: .cold, round: 0,
      budget: &budget)
    #expect(outcome.stop == nil)
    #expect(outcome.turns.map(\.turn) == [1, 2])
    let first = try #require(outcome.turns.first)
    let followUp = try #require(outcome.turns.last)
    #expect(!first.failed && !followUp.failed)
    // The scripted API answers the follow-up only when the first turn, thinking signature
    // included, comes back unchanged.
    var splitter = SentenceSplitter()
    let expected = splitter.append(chat.scriptedReplies[1]) + splitter.flush()
    #expect(followUp.requests.flatMap(\.sentences) == expected)
    #expect(first.requests.first?.tokens?.cacheWrite ?? 0 > 0)
    #expect(followUp.requests.first?.tokens?.cacheRead ?? 0 > 0)
    #expect(first.toolCheck.correct && followUp.toolCheck.correct)
    let cost = outcome.turns.flatMap(\.requests).reduce(0) { $0 + $1.cost }
    #expect(cost > 0)
    #expect(abs(budget.spent - cost) < 1e-12)
  }

  @Test func scriptedAPIRejectsAThinkingBlockThatCameBackChanged() async throws {
    let request = MessagesRequest(
      model: Configuration.sonnet, maxTokens: 100, system: ["Uriel"],
      messages: [
        Message(role: .user, content: [.text("Hi")]),
        Message(
          role: .assistant,
          content: [ContentBlock(json: ["type": .string("thinking"), "thinking": .string("")])]),
        Message(role: .user, content: [.text("Again")]),
      ], effort: .low)
    var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    urlRequest.httpBody = try request.jsonData()
    #expect(try await ScriptedTransport().send(urlRequest).statusCode == 400)
  }

  @Test func toolTurnAnswersTheCallAndMeasuresTheReplyAfterIt() async throws {
    var budget = Budget(cap: 3)
    let outcome = await runner().run(
      try fixture("timer-2"), config: try config("haiku-low"), sessionTag: "b", phase: .warm,
      round: 1, budget: &budget)
    let turn = try #require(outcome.turns.first)
    #expect(outcome.turns.count == 1)
    #expect(turn.requests.map(\.stopReason) == ["tool_use", "end_turn"])
    #expect(turn.requests[0].toolCalls == [#"set_timer {"duration_seconds":660,"label":"pasta"}"#])
    #expect(turn.toolCheck.correct)
    #expect(turn.requests[1].sentences == ["Pasta timer set for eleven minutes."])
    // The turn's first sentence comes after the whole first request.
    let firstSentence = try #require(turn.firstSentence)
    #expect(firstSentence >= turn.requests[1].startOffset)
    #expect(turn.requests[1].startOffset >= (turn.requests[0].total ?? 0))
  }

  @Test func measuresAreOrderedWithinARequest() async throws {
    var budget = Budget(cap: 3)
    let outcome = await runner().run(
      try fixture("chat-5"), config: try config("sonnet-medium"), sessionTag: "c", phase: .warm,
      round: 1, budget: &budget)
    for request in outcome.turns.flatMap(\.requests) {
      let firstText = try #require(request.firstTextDelta)
      let firstSentence = try #require(request.firstSentence)
      let total = try #require(request.total)
      #expect(firstText <= firstSentence && firstSentence <= total)
      #expect(request.sentenceGaps.count == request.sentences.count - 1)
      #expect(request.sentenceGaps.allSatisfy { $0 >= 0 })
    }
  }

  @Test func budgetStopsTheRunBeforeTheFirstRequest() async throws {
    var budget = Budget(cap: 0.000_001)
    let outcome = await runner().run(
      try fixture("chat-1"), config: try config("haiku-low"), sessionTag: "d", phase: .cold,
      round: 0, budget: &budget)
    #expect(outcome.stop == "the budget cap")
    let request = try #require(outcome.turns.first?.requests.first)
    #expect(request.attempts == 0)
    #expect(request.error?.hasPrefix("not sent") == true)
    #expect(budget.spent == 0)
  }

  @Test func scheduleRunsEachUtteranceOnceColdThenTenTimesWarm() throws {
    let configs = Configuration.all
    let order = Matrix.schedule(configs: configs, utterances: Fixtures.utterances, warmRounds: 10)
    let pairs = Fixtures.utterances.count * configs.count
    #expect(order.count == pairs * 11 + configs.count)
    #expect(order.prefix(pairs).allSatisfy { $0.phase == .cold })
    #expect(order.dropFirst(pairs).prefix(configs.count).allSatisfy { $0.phase == .prime })
    #expect(order.dropFirst(pairs + configs.count).allSatisfy { $0.phase == .warm })
    for utterance in Fixtures.utterances {
      for config in configs {
        let runs = order.filter { $0.utterance.id == utterance.id && $0.config == config }
        #expect(runs.filter { $0.phase == .warm }.map(\.round) == Array(1...10))
      }
    }
    // The prime is one request: the first turn of the first utterance.
    #expect(order.first { $0.phase == .prime }?.utterance.turns.count == 1)
  }

  @Test func fixturesAreLongEnoughToCacheAndCoverThePlan() {
    #expect(Fixtures.estimatedPrefixTokens >= 700)
    let kinds = Fixtures.utterances.map(\.kind)
    #expect(kinds.filter { $0 == .chat }.count == 6)
    #expect(kinds.filter { $0 == .openApp }.count == 3)
    #expect(kinds.filter { $0 == .timer }.count == 3)
    #expect(Fixtures.utterances.filter { $0.kind == .chat }.allSatisfy { $0.turns.count == 2 })
    #expect(sampleSentences().count == 30)
  }
}
