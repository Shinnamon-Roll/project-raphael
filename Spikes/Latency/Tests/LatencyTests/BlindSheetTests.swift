import Foundation
import Testing

@testable import Latency

@Suite("Blind rating sheet")
struct BlindSheetTests {
  private let configs = Configuration.all.map(\.id)
  private let chats = ["chat-1", "chat-2", "chat-3"]

  @Test func sameSeedGivesSameOrder() {
    let first = Report.blindOrder(configs: configs, utterances: chats, seed: 7)
    let second = Report.blindOrder(configs: configs, utterances: chats, seed: 7)
    #expect(first == second)
  }

  @Test func everyConfigurationAppearsOncePerConversation() {
    let order = Report.blindOrder(configs: configs, utterances: chats, seed: 7)
    #expect(Set(order.keys) == Set(chats))
    for chat in chats { #expect(order[chat]?.sorted() == configs.sorted()) }
  }

  @Test func orderIsShuffled() {
    let orders = (0..<20).map { seed in
      Report.blindOrder(configs: configs, utterances: chats, seed: UInt64(seed))["chat-1"] ?? []
    }
    #expect(Set(orders).count > 1)
    #expect(orders.contains { $0 != configs })
  }

  @Test func keyNamesTheConfigurationBehindEachLabel() {
    // One warm conversation per configuration, whose answers carry the configuration's number.
    let turns = configs.enumerated().flatMap { number, config in
      [1, 2].map { turn in
        var request = RequestMeasure(startOffset: 0)
        request.sentences = ["Answer \(number) turn \(turn)."]
        return TurnRecord(
          config: config, phase: .warm, round: 1, utterance: "chat-1", kind: .chat, turn: turn,
          requests: [request])
      }
    }
    let report = Report(
      name: "test",
      info: RunInfo(
        mode: "test", started: .now, budget: 3, configs: configs, warmRounds: 1),
      turns: turns, speech: nil)
    let (sheet, key) = report.blindSheet
    let order = Report.blindOrder(
      configs: configs, utterances: Fixtures.utterances.filter { $0.kind == .chat }.map(\.id),
      seed: Report.blindSeed)
    let labels = ["A", "B", "C", "D", "E"]
    let chat1 = order["chat-1"] ?? []
    #expect(key.contains("| chat-1 | " + chat1.map { "`\($0)`" }.joined(separator: " | ") + " |"))
    // In the sheet, label A's answer is the answer of the first configuration in the key.
    let section = sheet.components(separatedBy: "## chat-1")[1].components(
      separatedBy: "## chat-2")[0]
    for (label, config) in zip(labels, chat1) {
      let answer = section.components(separatedBy: "### \(label)")[1].components(
        separatedBy: "Rating")[0]
      let number = configs.firstIndex(of: config) ?? -1
      #expect(answer.contains("Answer \(number) turn 1."))
      #expect(answer.contains("Answer \(number) turn 2."))
    }
    // The sheet itself never names a configuration.
    for config in configs { #expect(!sheet.contains(config)) }
  }
}
